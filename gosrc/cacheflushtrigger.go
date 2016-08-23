package main

import (
	"database/sql"
	"github.com/BurntSushi/toml"
	_ "github.com/go-sql-driver/mysql"
	"github.com/jasonlvhit/gocron"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

/*
drop table if exists cache_flush_trigger;
create table cache_flush_trigger (
    job_name varchar(30) not null comment '刷新任务名称',
    job_desc varchar(100) not null comment '刷新任务描述',
    flush_url varchar(100) not null comment '刷新调用的URL',
    token bigint not null comment '令牌值，需要刷新时，重置令牌值为0',
    primary key (job_name)
)engine=innodb default charset=utf8mb4 comment='缓存刷新配置';
insert into cache_flush_trigger values('MobileNumber->MerchantInfo',
    '手机号码查商户信息缓存刷新', 'http://127.0.0.1:9001/flushall', 0);
update cache_flush_trigger set token = 0 where job_name = 'MobileNumber->MerchantInfo';

编译: go build gosrc/cacheflushtrigger.go
运行命令: nohup ./cacheflushtrigger gosrc/cacheflushtrigger.toml > cacheflushtrigger.log &
*/
func main() {
	logChan := make(chan string)
	go func() {
		for msg := range logChan {
			log.Print(msg)
		}
	}()

	logChan <- "Start to run"
	config := readConfig()

	gocron.Every(60).Seconds().Do(mainTask, config, logChan)
	<-gocron.Start()
}

func mainTask(config CacheFlushTriggerConfig, logChan chan string) {
	db := getDb(config.Db)
	var wg sync.WaitGroup

	jobsCount := doJobs(db, logChan)
	wg.Add(jobsCount)

	go func() {
		wg.Wait()
		db.Close()
	}()
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

func updateJobToken(db *sql.DB, job *Job) {
	stmt, err := db.Prepare("update cache_flush_trigger set token = ? where job_name = ?")
	checkJobErr(err)
	defer stmt.Close()

	_, err = stmt.Exec(time.Now().Unix(), job.jobName)
	checkJobErr(err)
}

type Job struct {
	jobName  string
	jobDesc  string
	flushUrl string
	token    int64
}

func doJobs(db *sql.DB, logChan chan string) int {
	rows, err := db.Query("select job_name, job_desc, " +
		"flush_url, token from cache_flush_trigger " +
		"where token = 0")
	checkJobErr(err)
	defer rows.Close()

	jobsCount := 0
	for rows.Next() {
		row := new(Job)

		err := rows.Scan(&row.jobName, &row.jobDesc, &row.flushUrl, &row.token)
		checkJobErr(err)
		jobsCount++

		go doJob(db, row, logChan)
	}

	err = rows.Err()
	checkJobErr(err)

	if jobsCount == 0 {
		logChan <- "no available jobs for cache flush"
	}

	return jobsCount
}

func doJob(db *sql.DB, job *Job, logChan chan string) {
	err := httpGet(job, logChan)
	if err == nil {
		updateJobToken(db, job)
	}
}

func httpGet(job *Job, logChan chan string) error {
	logChan <- job.jobName + " " + job.flushUrl
	resp, err := http.Get(job.flushUrl)
	if err != nil {
		logChan <- err.Error()
		return err
	}

	defer resp.Body.Close()
	body, err := ioutil.ReadAll(resp.Body)
	bodyStr := string(body)
	logChan <- job.jobName + " " + bodyStr
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
