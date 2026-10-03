# explore-jena-sparql

A local [Apache Jena Fuseki](https://jena.apache.org/documentation/fuseki2/) SPARQL server backed by a persistent [TDB2](https://jena.apache.org/documentation/tdb2/) store, run with Docker Compose.

I used this to follow the [Jena SPARQL tutorial](https://jena.apache.org/tutorials/sparql_data.html).

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

## 9. Query from a VS Code notebook

You can run queries against Fuseki from a notebook in VS Code with the [SPARQL Notebook](https://marketplace.visualstudio.com/items?itemName=Zazuko.sparql-notebook) extension (`zazuko.sparql-notebook`). Installing it also pulls in the Stardog extensions for SPARQL syntax highlighting and auto-completion.

1. **Install the extension.**
   ```bash
   code --install-extension zazuko.sparql-notebook
   ```
   Or search for "SPARQL Notebook" in the Extensions view. If `code` isn't found, run **Shell Command: Install 'code' command in PATH** from the Command Palette first.
2. **Start the server** (step 1) and load some data (step 4).
3. **Open a notebook.** Open [`notebooks/queries.sparqlbook`](notebooks/queries.sparqlbook), or create a new file ending in `.sparqlbook`. VS Code opens it as a notebook. If it opens as plain JSON, right-click the file, pick **Open With...**, and choose **SPARQL Notebook**.
4. **Point each cell at Fuseki.** Put this comment at the top of every code cell:
   ```sparql
   # [endpoint=http://localhost:3030/ds/sparql]
   SELECT * WHERE { ?s ?p ?o } LIMIT 10
   ```
   The comment is saved in the `.sparqlbook` file, so the endpoint goes into version control with the notebook. The cells in `notebooks/queries.sparqlbook` already have it.
5. **Run a cell.** Press Ctrl+Enter (Option+Enter on macOS), or click the run button next to the cell. The cell's status bar shows which endpoint it used.

💡 **Optional: a default connection.** To skip the comment, add a connection in the extension's **Connections** panel. Open it from the **Sparql Notebook** icon in the activity bar, or run **Sparql Notebook: Focus on Connections View** from the Command Palette. If the icon is missing, right-click the activity bar and tick **Sparql Notebook**. Click **+**, enter `http://localhost:3030/ds/sparql` with no user or password, then click the plug icon to connect. Cells without an endpoint comment use this connection. The extension saves connections in your VS Code user profile, not in the repo, so everyone who clones the repo has to add the connection themselves.

💡 To run a query that lives in a file such as [`queries/q1.rq`](queries/q1.rq), use **Add Query from File...** in the cell toolbar. The cell loads the file when it runs, and saving the notebook also saves the file.

💡 To show SELECT results as a table by default: in a cell's output, switch the renderer to `application/sparql-results+json`, then run **Notebook: Save Mimetype Display Order** from the Command Palette.

⚠️ The notebook runs queries only (SELECT, ASK, CONSTRUCT, DESCRIBE). Send updates with `curl` as in step 6.

⚠️ Right-clicking an RDF file and choosing **SPARQL Notebook: Use File as Store** queries that file in an in-memory store inside VS Code. It doesn't touch Fuseki.

## Notes

- ⚠️ **The data endpoints have no authentication.** Only the admin API under `/$/` needs a password. Anyone who can reach port 3030 can read and write `/ds` through the query, update and data endpoints. This setup is meant for local development only.
- ⚠️ **Avoid `|` and `&` in the admin password.** Both characters break the password substitution in `entrypoint.sh`.

## Stop the server

```bash
docker compose down        # keeps the data
docker compose down -v     # also deletes the data
```
