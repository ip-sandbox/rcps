#!/bin/sh
# comment
echo $# ${#var} a#b x#y \# 16#ff # real
echo '#' "#" '# in' # c
n=$((16#ff)) # c
echo $$# # c
