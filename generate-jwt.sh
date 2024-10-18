#!/bin/bash
if [[ ! -f jwt.hex ]]
then
  openssl rand -hex 32 | tr -d "\n" | tee > jwt.hex
else
  echo "jwt.hex already exists!"
fi