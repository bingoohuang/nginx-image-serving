#!/usr/bin/python
#use to convert img of the directory into a given size
#coding=utf-8
#usage: $0  targetDirectory sizes
#example: ./imgbatchconvert.py /Users/fengyu/HI-PROJECT/nginx-image-serving/tools/timg 60x60,100x100

import os
import os.path
import sys

def convert(fullpath):
  s = sys.argv[2].split(',')
  for size in s :   
   cmd = 'convert %s -unsharp 0x1 -resize %s^ -gravity center -extent %s %s.%s' % (fullpath ,size ,size ,fullpath ,size)
   print cmd
   os.system(cmd)

for parent,_,filenames in os.walk(sys.argv[1]):
 for filename in filenames:
  print "the full name of the file is:" + os.path.join(parent,filename)
  path = os.path.join(parent,filename)
  postfix = filename[filename.rfind('.'):]
  print postfix
  if '.jpg' == postfix.lower() or '.png' == postfix.lower() :
   convert(path)
  print ""
