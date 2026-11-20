cat <<EOF # remove me
# body line
  not # comment
EOF
cat <<-EOT # c2
	# tab body
	EOT
cat <<'A' <<"B" # c3
# a body
A
# b body
B
cat <<< "#x" # c4
cat <<\EOF2
# body2
EOF2
echo done # c5
