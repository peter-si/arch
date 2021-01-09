#!/bin/sh

PASSWORD="$1"

passwd root --stdin <<EOF
$PASSWORD
EOF
