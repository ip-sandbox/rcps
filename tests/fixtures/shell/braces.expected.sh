echo ${var#prefix} ${var##*/} ${var%%x}
echo ${a:-"}"} ${b:-'}'}
case $x in
  a) echo a ;;
  *) echo b ;;
esac
echo $'it\'s # x'
x=$((1 << 3))
