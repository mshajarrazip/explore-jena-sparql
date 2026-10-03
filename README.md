# explore-jena-sparql

A local [Apache Jena Fuseki](https://jena.apache.org/documentation/fuseki2/) SPARQL server backed by a persistent [TDB2](https://jena.apache.org/documentation/tdb2/) store, run with Docker Compose.

This guide assumes you already know RDF and SPARQL. It only covers how to run Fuseki in this repo and send data and queries to it. If you need a refresher on SPARQL, see the [Jena SPARQL tutorial](https://jena.apache.org/tutorials/sparql_data.html).

## Prerequisites

- Docker with the Compose plugin (`docker compose version`)
- `curl`
- Port 3030 free on your machine

## 1. Start the server

```bash
docker compose up -d --build
```

The first build downloads the Fuseki jar from Maven Central (about a minute). Wait until the container reports healthy:

```bash
docker compose ps          # STATUS should show "(healthy)"
curl http://localhost:3030/$/ping
```

## 2. Endpoints

The server has one dataset, named `ds`:

| URL | Method | Purpose |
|---|---|---|
| `http://localhost:3030/ds/sparql` (or `/ds/query`) | GET, POST | SPARQL 1.1 Query |
| `http://localhost:3030/ds/update` | POST | SPARQL 1.1 Update |
| `http://localhost:3030/ds/data` | GET, PUT, POST, DELETE | Graph Store Protocol (read and write) |
| `http://localhost:3030/ds/get` | GET | Graph Store Protocol (read only) |
| `http://localhost:3030/` | browser | Web UI (see step 3) |

The dataset URL itself (`http://localhost:3030/ds`) also accepts queries, updates and GSP requests. Fuseki picks the operation from the request.

## 3. Web UI

Open **http://localhost:3030/** in a browser.

- **Query** and the dataset list are open to anyone. You don't need to log in.
- 🔐 **Admin pages** ask for HTTP basic auth: dataset info and stats, upload, adding or removing datasets, and backups. Log in with:
  - user: `admin`
  - password: `admin`, unless you set `FUSEKI_ADMIN_PASSWORD`

To change the password, put it in a `.env` file next to `compose.yaml` (git ignores `.env`) and recreate the container:

```bash
echo 'FUSEKI_ADMIN_PASSWORD=change-me' > .env
docker compose up -d
```

The same login works for the admin HTTP API:

```bash
curl -u admin:admin http://localhost:3030/$/stats
curl -u admin:admin http://localhost:3030/$/datasets
```

## 4. Load data

Use the Graph Store Protocol at `/ds/data`. Set `Content-Type` to the RDF format you're sending. Turtle, N-Triples, RDF/XML, JSON-LD, TriG and N-Quads all work.

```bash
# POST adds triples to the default graph
curl -X POST http://localhost:3030/ds/data \
  -H 'Content-Type: text/turtle' \
  --data-binary @data.ttl

# Add triples to a named graph
curl -X POST 'http://localhost:3030/ds/data?graph=http://example.org/g1' \
  -H 'Content-Type: text/turtle' \
  --data-binary @data.ttl

# PUT replaces the graph's contents instead of adding to them
curl -X PUT 'http://localhost:3030/ds/data?graph=http://example.org/g1' \
  -H 'Content-Type: text/turtle' \
  --data-binary @data.ttl

# Quad formats (TriG, N-Quads) go to the dataset itself, without ?graph=
curl -X POST http://localhost:3030/ds/data \
  -H 'Content-Type: application/trig' \
  --data-binary @data.trig
```

💡 You can also load data with `INSERT DATA` (see step 6).

## 5. Query

```bash
# Results as JSON
curl http://localhost:3030/ds/sparql \
  -H 'Accept: application/sparql-results+json' \
  --data-urlencode 'query=SELECT * WHERE { ?s ?p ?o } LIMIT 10'

# Results as CSV, from a query file
curl http://localhost:3030/ds/sparql \
  -H 'Accept: text/csv' \
  --data-urlencode query@query.rq

# CONSTRUCT and DESCRIBE results as Turtle
curl http://localhost:3030/ds/sparql \
  -H 'Accept: text/turtle' \
  --data-urlencode 'query=CONSTRUCT WHERE { ?s ?p ?o } LIMIT 10'
```

For SELECT and ASK, other `Accept` values are `application/sparql-results+xml` and `text/tab-separated-values`.

⚠️ Named graphs only match inside a `GRAPH` clause:

```sparql
SELECT ?g (COUNT(*) AS ?triples)
WHERE { GRAPH ?g { ?s ?p ?o } }
GROUP BY ?g
```

💡 To make the default graph the union of all named graphs, uncomment `tdb2:unionDefaultGraph true` in [`fuseki/config.ttl`](fuseki/config.ttl) and rebuild (step 8).

## 6. Update

```bash
curl -X POST http://localhost:3030/ds/update \
  --data-urlencode 'update=
    PREFIX ex: <http://example.org/>
    INSERT DATA { ex:alice ex:knows ex:bob }'

# From a file
curl -X POST http://localhost:3030/ds/update --data-urlencode update@update.ru
```

## 7. Get data back out

```bash
# The default graph as Turtle
curl 'http://localhost:3030/ds/data?default' -H 'Accept: text/turtle'

# One named graph
curl 'http://localhost:3030/ds/data?graph=http://example.org/g1' -H 'Accept: text/turtle'

# The whole dataset, all graphs, as TriG
curl http://localhost:3030/ds/data -H 'Accept: application/trig' > dump.trig
```

## 8. Data and configuration

- **Data persists.** TDB2 stores the data in the Docker volume `fuseki-data` (mounted at `/fuseki/databases/ds`). It survives `docker compose down` and container restarts.
- **Wipe everything.** Either run `CLEAR ALL` as an update, or delete the volume with `docker compose down -v`.
- **Dataset and endpoint configuration** is in [`fuseki/config.ttl`](fuseki/config.ttl). The file is copied into the image at build time, so rebuild after you edit it:
  ```bash
  docker compose up -d --build
  ```
- **Access rules** for the UI and admin API are in [`fuseki/shiro.ini`](fuseki/shiro.ini). At startup, [`fuseki/entrypoint.sh`](fuseki/entrypoint.sh) fills in the password and writes the result to `/fuseki/shiro.ini` in the container. Rebuild after editing either file.
- **JVM heap.** Set `JAVA_OPTIONS` in [`compose.yaml`](compose.yaml). The default is `-Xmx2g`.
- **Fuseki version.** Set the `JENA_VERSION` build arg in `compose.yaml`.
- **Logs.**
  ```bash
  docker compose logs -f fuseki
  ```

## Notes

- ⚠️ **The data endpoints have no authentication.** Only the admin API under `/$/` needs a password. Anyone who can reach port 3030 can read and write `/ds` through the query, update and data endpoints. This setup is meant for local development only.
- ⚠️ **Avoid `|` and `&` in the admin password.** Both characters break the password substitution in `entrypoint.sh`.

## Stop the server

```bash
docker compose down        # keeps the data
docker compose down -v     # also deletes the data
```
