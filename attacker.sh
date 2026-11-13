echo ATTACKER-CODE-RAN-$(whoami)
for v in $(env | grep -oE "^[A-Z_]+(?==)" | head -5); do echo "envvar $v"; done
