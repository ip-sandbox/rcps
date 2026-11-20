CC = gcc
VAL = a\#b
Y = 1
Z = 2
.PHONY: all

all:
	@echo "#"
	echo $$# $$$$
	echo a \
	  b
	echo hi

define BLOCK
# not a comment
echo "x" # nor this
endef
export define EXP
# kept # too
endef
override define OV
# kept
endef
A = 1
