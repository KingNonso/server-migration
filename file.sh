#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <file name>"
    exit 1
fi

FILE=$1
chmod +x "$FILE"
./"$FILE"
