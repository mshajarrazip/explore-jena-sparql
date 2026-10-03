#!/usr/bin/env bash
# Load every RDF file under data/ into Fuseki's default graph, so queries work
# without FROM or GRAPH.
#
# Each run clears the default graph first and then adds every file, so
# re-running reloads the data instead of duplicating blank nodes.
#
# Usage:
#   scripts/load-data.sh            # clear the default graph, load every file
#   scripts/load-data.sh --reset    # DROP ALL first (also removes named graphs)
#   scripts/load-data.sh --purge    # DROP ALL and stop, without loading anything
#
# Environment:
#   FUSEKI_URL  dataset URL      (default: http://localhost:3030/ds)
#   DATA_DIR    folder to load   (default: data/ next to this script's parent)

# Re-run under bash when started as `sh scripts/load-data.sh` (on macOS, sh is
# bash in POSIX mode, which lacks the process substitution used below).
case "${BASH_VERSION:-}:${SHELLOPTS:-}:" in
  :*|*:posix:*) exec bash "$0" "$@" ;;
esac

set -euo pipefail

FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030/ds}"
DATA_DIR="${DATA_DIR:-$(cd "$(dirname "$0")/.." && pwd)/data}"

reset=false
purge=false
case "${1:-}" in
  "") ;;
  --reset) reset=true ;;
  --purge) purge=true ;;
  *) echo "usage: $0 [--reset | --purge]" >&2; exit 2 ;;
esac

if ! curl -fsS "${FUSEKI_URL%/*}/\$/ping" >/dev/null; then
  echo "Fuseki is not reachable at ${FUSEKI_URL%/*}. Start it with: docker compose up -d" >&2
  exit 1
fi

update() {
  curl -fsS -X POST "$FUSEKI_URL/update" --data-urlencode "update=$1" >/dev/null
}

# Run a SPARQL query and print the single value of a one-row CSV result.
query_value() {
  curl -fsS "$FUSEKI_URL/sparql" -H 'Accept: text/csv' --data-urlencode "query=$1" \
    | tail -n 1 | tr -d '\r'
}

# Pull "count" (triples + quads) out of the JSON that Fuseki returns for an upload.
upload_count() {
  sed -n 's/.*"count" *: *\([0-9][0-9]*\).*/\1/p'
}

count_all() {
  query_value "SELECT (COUNT(*) AS ?n) WHERE { { ?s ?p ?o } UNION { GRAPH ?g { ?s ?p ?o } } }"
}

if $reset || $purge; then
  update 'DROP ALL'
  echo "dropped all graphs"
  $purge && exit 0
else
  update 'CLEAR DEFAULT'
  echo "cleared the default graph"
fi

loaded=0
skipped=0
failed=0
while IFS= read -r -d '' file; do
  rel="${file#"$DATA_DIR"/}"
  case "$file" in
    *.ttl)             type=text/turtle ;;
    *.nt)              type=application/n-triples ;;
    *.rdf|*.owl|*.xml) type=application/rdf+xml ;;
    *.jsonld)          type=application/ld+json ;;
    *.n3)              type=text/n3 ;;
    # Quad files name their own graphs; their triples land in those graphs.
    *.trig)            type=application/trig ;;
    *.nq)              type=application/n-quads ;;
    *) echo "skip  $rel (unknown extension)"; skipped=$((skipped + 1)); continue ;;
  esac

  before=$(count_all)
  # POST adds to the default graph (PUT would replace it with this one file).
  response=$(curl -sS -w '\n%{http_code}' -X POST "$FUSEKI_URL/data" \
    -H "Content-Type: $type" --data-binary @"$file")
  status="${response##*$'\n'}"
  if [ "${status:0:1}" != 2 ]; then
    echo "FAIL  $rel (HTTP $status)" >&2
    echo "${response%$'\n'*}" | sed 's/^/      /' >&2
    failed=$((failed + 1))
    continue
  fi

  # Sanity check: the file parsed to some triples, and querying the store
  # shows it grew. Triples already loaded from another file are stored once,
  # so "new" can be lower than "parsed".
  parsed=$(printf '%s\n' "$response" | upload_count)
  after=$(count_all)
  added=$((after - before))
  if [ -z "$parsed" ] || [ "$parsed" -eq 0 ]; then
    echo "FAIL  $rel (no triples parsed)" >&2
    failed=$((failed + 1))
  elif [ "$added" -eq 0 ]; then
    echo "ok    $rel ($parsed triples parsed, all already loaded from other files)"
    loaded=$((loaded + 1))
  else
    echo "ok    $rel ($parsed triples parsed, $added new)"
    loaded=$((loaded + 1))
  fi
done < <(find "$DATA_DIR" -type f ! -name '.*' -print0 | sort -z)

default=$(query_value "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")
echo "done: $loaded loaded, $skipped skipped, $failed failed"
echo "      the default graph now holds $default triples"

[ "$failed" -eq 0 ]
