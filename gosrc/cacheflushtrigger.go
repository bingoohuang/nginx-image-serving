package main

import (
	"database/sql"
	"fmt"
	"github.com/BurntSushi/toml"
	_ "github.com/go-sql-driver/mysql"
	"github.com/jasonlvhit/gocron"
	"github.com/lunny/nodb"
	"github.com/lunny/nodb/config"
	"io/ioutil"
	"log"
	"net/http"
	"os"
)

/*
drop table if exists cache_flush_trigger;
create table cache_flush_trigger (
    job_name varchar(30) not null comment '刷新任务名称',
    job_desc varchar(100) not null comment '刷新任务描述',
    flush_url varchar(100) not null comment '刷新调用的URL',
    token bigint not null comment '令牌值，需要刷新时，更新令牌值为新值',
    primary key (job_name)
)engine=innodb default charset=utf8mb4 comment='缓存刷新配置';
insert into cache_flush_trigger values('MobileNumber->MerchantInfo',
    '手机号码查商户信息缓存刷新', 'http://127.0.0.1:9001/flushall', 0);
update cache_flush_trigger set token = token + 1 where job_name = 'MobileNumber->MerchantInfo';

编译: go build gosrc/cacheflushtrigger.go
运行命令: nohup ./cacheflushtrigger gosrc/cacheflushtrigger.toml > cacheflushtrigger.log &
tail -f cacheflushtrigger.log
2016/08/23 09:34:22 Start to run
2016/08/23 09:35:22 MobileNumber->MerchantInfo's token changed to 1471915006 start to Get http://127.0.0.1:9001/flushall
2016/08/23 09:35:22 MobileNumber->MerchantInfo result OK
2016/08/23 09:36:23 MobileNumber->MerchantInfo's token changed to 1471915007 start to Get http://127.0.0.1:9001/flushall
2016/08/23 09:36:23 MobileNumber->MerchantInfo result OK
2016/08/23 09:37:24 MobileNumber->MerchantInfo's token 1471915007 is not changed
2016/08/23 09:38:25 MobileNumber->MerchantInfo's token 1471915007 is not changed
*/
func main() {
	log.Print("Start to run")
	config := readConfig()
	nodb, tempDir, _ := OpenTemp()
	defer os.RemoveAll(tempDir)

	gocron.Every(60).Seconds().Do(mainTask, config, nodb)
	<-gocron.Start()
}

func mainTask(config CacheFlushTriggerConfig, nodb *Nodb) {
	db := getDb(config.Db)
	defer db.Close()

	doJobs(db, nodb)
}

type CacheFlushTriggerConfig struct {
	Db string
}

func readConfig() CacheFlushTriggerConfig {
	fpath := "cacheflushtrigger.toml"
	if len(os.Args) > 1 {
		fpath = os.Args[1]
	}

	config := CacheFlushTriggerConfig{}
	if _, err := toml.DecodeFile(fpath, &config); err != nil {
		checkJobErr(err)
	}

	return config
}

type Job struct {
	jobName  string
	jobDesc  string
	flushUrl string
	token    string
}

func doJobs(db *sql.DB, nodb *Nodb) {
	rows, err := db.Query("select job_name, job_desc, " +
		"flush_url, token from cache_flush_trigger ")
	checkJobErr(err)
	defer rows.Close()

	for rows.Next() {
		row := new(Job)

		err := rows.Scan(&row.jobName, &row.jobDesc, &row.flushUrl, &row.token)
		checkJobErr(err)

		doJob(row, nodb)
	}

	err = rows.Err()
	checkJobErr(err)
}

func doJob(job *Job, nodb *Nodb) {
	token, err := nodb.Get(job.jobName)
	if token == job.token {
		log.Print(job.jobName, "'s token ", job.token, " is not changed ")
		return
	}

	log.Print(job.jobName, "'s token changed to ", job.token, " start to Get ", job.flushUrl)

	err = httpGet(job)
	if err == nil {
		nodb.Set(job.jobName, job.token)
	}
}

func httpGet(job *Job) error {
	resp, err := http.Get(job.flushUrl)
	if err != nil {
		log.Print(job.jobName, " result ", err.Error())
		return err
	}

	defer resp.Body.Close()
	body, err := ioutil.ReadAll(resp.Body)
	bodyStr := string(body)
	log.Print(job.jobName, " result ", bodyStr)
	return err
}

func getDb(dataSourceName string) *sql.DB {
	db, err := sql.Open("mysql", dataSourceName)
	checkJobErr(err)

	return db
}

func checkJobErr(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

type Nodb struct {
	db *nodb.DB
}

func (db *Nodb) Set(key, value string) error {
	return db.db.Set([]byte(key), []byte(value))
}

func (db *Nodb) Get(key string) (string, error) {
	value, err := db.db.Get([]byte(key))
	str := string(value)
	return str, err
}

func (db *Nodb) Exists(key string) bool {
	value, _ := db.db.Exists([]byte(key))
	return value == 1
}

func OpenTemp() (*Nodb, string, error) {
	cfg := new(config.Config)

	cfg.DataDir, _ = ioutil.TempDir(os.TempDir(), "nodb")
	nodbs, err := nodb.Open(cfg)
	if err != nil {
		fmt.Printf("nodb: error opening db: %v", err)
	}

	db, err := nodbs.Select(0)

	return &Nodb{db}, cfg.DataDir, err
}
