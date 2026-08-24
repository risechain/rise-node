#!/bin/bash
if [[ ! -f jwt.txt ]]
then
  # 0600 and never echoed: this secret guards the engine API
  (umask 077 && openssl rand -hex 32 | tr -d "\n" > jwt.txt)
  echo "jwt.txt generated"
else
  echo "jwt.txt already exists!"
fi
