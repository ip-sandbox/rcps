echo ${var#prefix} ${var##*/} ${var%%x} # c
echo ${a:-"}"} ${b:-'}'} # c2
case $x in
  a) echo a ;; # c3
  *) echo b ;; # c4
esac
echo $'it\'s # x' # c5
x=$((1 << 3)) # c6
