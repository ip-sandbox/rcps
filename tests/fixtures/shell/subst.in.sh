echo $(cmd # c
)
x="$(echo "#")" # c2
y=`echo # not comment` # c3
z=$(echo $(echo a # c4
) b) # c5
w="a $(echo b # c6
) c" # c7
