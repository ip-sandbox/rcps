CC = gcc # compiler
VAL = a\#b # real
# whole line
# comment \
   continues here
Y = 1 # c \
  more
Z = 2
.PHONY: all # c

all:
	@echo "#" # shell comment
	# a recipe comment
	echo $$# $$$$ # c
	echo a \
	  b # c2
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
A = 1 # last
