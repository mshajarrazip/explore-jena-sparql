#!/usr/bin/env bash
# List, load and purge the RDF files under data/ in Fuseki.
#
# Triple files (.ttl, .rdf, ...) go into the default graph, so queries work
# without FROM or GRAPH. Quad files (.trig, .nq) also fill the named graphs
# they declare.
#
# Usage:
#   scripts/load-data.sh                        # list the files, numbered
#   scripts/load-data.sh --upload               # load every file
#   scripts/load-data.sh --upload --filter 1,3  # load files 1 and 3
#   scripts/load-data.sh --purge                # remove everything
#   scripts/load-data.sh --purge --filter 2     # remove file 2 only
#
# --filter takes file numbers from the list, comma-separated or repeated
# (--filter 1 --filter 3). Without --upload or --purge it just lists them.
#
# Fuseki can't tell which triples came from which file, so the script records
# the loaded files in $STATE_FILE and rebuilds the dataset from that set on
# every --upload or --purge. Uploading a loaded file again therefore doesn't
# duplicate its blank nodes, and purging a file leaves the others in place.
# Data added to Fuseki outside this script is removed on each rebuild.
#
# Environment:
#   FUSEKI_URL  dataset URL      (default: http://localhost:3030/ds)
#   DATA_DIR    folder to load   (default: data/ next to this script's parent)
#   STATE_FILE  loaded-file list (default: .load-data-state next to data/)

# Re-run under bash when started as `sh scripts/load-data.sh` (on macOS, sh is
# bash in POSIX mode, which lacks the process substitution used below).
case "${BASH_VERSION:-}:${SHELLOPTS:-}:" in
  :*|*:posix:*) exec bash "$0" "$@" ;;
esac

set -euo pipefail

FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030/ds}"
DATA_DIR="${DATA_DIR:-$(cd "$(dirname "$0")/.." && pwd)/data}"
STATE_FILE="${STATE_FILE:-$(dirname "$DATA_DIR")/.load-data-state}"

usage() {
  echo "usage: $0 [--upload | --purge] [--filter N[,N...]]" >&2
  exit 2
}

action=list
filters=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upload) [ "$action" = list ] || usage; action=upload ;;
    --purge)  [ "$action" = list ] || usage; action=purge ;;
    --filter)
      [ $# -ge 2 ] || usage
      filters="$filters,$2"
      shift ;;
    --filter=*) filters="$filters,${1#--filter=}" ;;
    -h|--help) sed -n '2,27s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) usage ;;
  esac
  shift
done

# Every file under data/, sorted, relative to data/. Numbering follows this order.
files=()
while IFS= read -r -d '' f; do
  files+=("${f#"$DATA_DIR"/}")
done < <(find "$DATA_DIR" -type f ! -name '.*' -print0 | sort -z)

if [ ${#files[@]} -eq 0 ]; then
  echo "no files in $DATA_DIR" >&2
  exit 1
fi

# contains <needle> <haystack...>
contains() {
  local needle="$1" item
  shift
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# Files picked by --filter (all files when there is no filter).
selected=()
if [ -z "$filters" ]; then
  selected=("${files[@]}")
else
  for n in $(echo "$filters" | tr ',' ' '); do
    case "$n" in
      *[!0-9]*) echo "--filter: '$n' is not a file number" >&2; exit 2 ;;
    esac
    if [ "$n" -lt 1 ] || [ "$n" -gt ${#files[@]} ]; then
      echo "--filter: there is no file $n (run without arguments to list them)" >&2
      exit 2
    fi
    selected+=("${files[$((n - 1))]}")
  done
  [ ${#selected[@]} -gt 0 ] || { echo "--filter: no file numbers given" >&2; exit 2; }
fi

# Files the last --upload or --purge left in Fuseki.
loaded=()
if [ -f "$STATE_FILE" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && loaded+=("$f")
  done < "$STATE_FILE"
fi

is_loaded() {
  [ ${#loaded[@]} -gt 0 ] && contains "$1" "${loaded[@]}"
}

# list_files [all]: numbered list, limited to --filter unless "all" is given.
list_files() {
  local i=0 f mark
  for f in "${files[@]}"; do
    i=$((i + 1))
    if [ "${1:-}" != all ] && ! contains "$f" "${selected[@]}"; then continue; fi
    if is_loaded "$f"; then mark="loaded"; else mark=""; fi
    printf '%3d  %-30s %s\n' "$i" "$f" "$mark"
  done
}

if [ "$action" = list ]; then
  list_files
  echo
  echo "load with --upload, remove with --purge; pick files with --filter N[,N...]"
  exit 0
fi

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

# The files Fuseki should hold after this run, in data/ order:
# --upload adds the selected files to the loaded ones, --purge removes them.
target=()
for f in "${files[@]}"; do
  if contains "$f" "${selected[@]}"; then picked=true; else picked=false; fi
  if [ "$action" = upload ]; then
    if $picked || is_loaded "$f"; then target+=("$f"); fi
  elif ! $picked && is_loaded "$f"; then
    target+=("$f")
  fi
done

if [ "$action" = purge ]; then
  for f in "${selected[@]}"; do
    if is_loaded "$f"; then echo "purge $f"; fi
  done
fi

# Rebuild from scratch, so files that stay loaded don't get duplicate blank nodes.
update 'DROP ALL'

failed=0
now_loaded=()
for rel in ${target[@]+"${target[@]}"}; do
  file="$DATA_DIR/$rel"
  case "$file" in
    *.ttl)             type=text/turtle ;;
    *.nt)              type=application/n-triples ;;
    *.rdf|*.owl|*.xml) type=application/rdf+xml ;;
    *.jsonld)          type=application/ld+json ;;
    *.n3)              type=text/n3 ;;
    # Quad files name their own graphs; their triples land in those graphs.
    *.trig)            type=application/trig ;;
    *.nq)              type=application/n-quads ;;
    *) echo "skip  $rel (unknown extension)"; continue ;;
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
    now_loaded+=("$rel")
  else
    echo "ok    $rel ($parsed triples parsed, $added new)"
    now_loaded+=("$rel")
  fi
done

if [ ${#now_loaded[@]} -gt 0 ]; then
  printf '%s\n' "${now_loaded[@]}" > "$STATE_FILE"
else
  rm -f "$STATE_FILE"
fi
loaded=(${now_loaded[@]+"${now_loaded[@]}"})

default=$(query_value "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")
named=$(query_value "SELECT (COUNT(DISTINCT ?g) AS ?n) WHERE { GRAPH ?g { ?s ?p ?o } }")
echo
list_files all
echo
echo "default graph: $default triples, named graphs: $named, failed: $failed"

[ "$failed" -eq 0 ]
