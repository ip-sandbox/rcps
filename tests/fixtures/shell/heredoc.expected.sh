cat <<EOF
# body line
  not # comment
EOF
cat <<-EOT
	# tab body
	EOT
cat <<'A' <<"B"
# a body
A
# b body
B
cat <<< "#x"
cat <<\EOF2
# body2
EOF2
echo done
