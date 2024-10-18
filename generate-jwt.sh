#!/bin/bash
if [[ ! -f jwt.txt ]]
then
  openssl rand -hex 32 | tr -d "\n" | tee > jwt.txt
else
  echo "jwt.txt already exists!"
fi