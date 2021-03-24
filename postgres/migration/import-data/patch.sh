for i in {0..9}; do
    kubectl patch cm/postgres-migration \
      -n app-$i \
      --type merge \
      -p "{\"data\":{\"DB\": \"app-$i\"}}"
done
