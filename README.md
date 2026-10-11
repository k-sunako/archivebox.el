# ArchiveBox for Emacs

Read-only ArchiveBox snapshot search from Emacs. Search saved pages and browse matching snapshots without leaving your editor.

## Features

- Search with ArchiveBox's REST API (`/api/v1/core/snapshots`).
- Choose `meta`, `contents`, or `deep` search modes.
- Browse results in a `tabulated-list-mode` buffer with title, URL, saved date, tags, and status.
- Page through results; open the ArchiveBox snapshot page or original URL.
- Uses Emacs built-ins only; no third-party package dependencies.

## Requirements

- GNU Emacs 27.1 or later.
- ArchiveBox with the v1 REST API enabled and an API token.

## Installation

Clone this repository and add it to `load-path`:

```elisp
(add-to-list 'load-path "~/src/archivebox.el")
(require 'archivebox)
```

Or use your preferred package manager with this repository as a recipe.

## Configuration

The defaults target an ArchiveBox instance on `127.0.0.1:8000`. Set these variables to match your deployment:

```elisp
(setq archivebox-base-url "http://127.0.0.1:8000"
      archivebox-api-host "127.0.0.1"
      archivebox-api-port "8000"
      archivebox-api-user "archivebox"
      archivebox-search-mode "contents"
      archivebox-page-size 50)
```

The API token is obtained from Emacs `auth-source`. For a simple non-GPG setup, create `~/.authinfo`, restrict its permissions, and add a matching entry:

```sh
umask 077
touch ~/.authinfo
chmod 600 ~/.authinfo
```

```text
machine 127.0.0.1 port 8000 login archivebox password REPLACE_WITH_YOUR_API_TOKEN
```

Enter the token in the file using an editor; do not put it in shell history, this repository, or a URL. `~/.authinfo` is plaintext, so keep it private and out of cloud-synced/shared folders. For a remotely reachable ArchiveBox instance, use HTTPS and configure the host/port to match its URL.

## Usage

Run `M-x archivebox-search`, enter a query, then choose a search mode.

| Key | Action |
| --- | --- |
| `RET` | Open the snapshot's ArchiveBox admin page |
| `o` | Open the original page URL |
| `s` | Search again |
| `m` | Change search mode |
| `g` | Repeat the current search |
| `n` / `p` | Next / previous page |
| `q` | Close the results buffer |

The default `RET` URL follows ArchiveBox's Django admin route. If your deployment uses another route, customize `archivebox-snapshot-url-function`.

## Tests

Run the ERT tests with Emacs:

```sh
emacs -Q --batch -L . -l tests/archivebox-tests.el
```

The test suite uses synthetic API responses and does not require an ArchiveBox server or API token.

## Scope

This first version is read-only: it searches and displays snapshots but does not add, edit, or delete archived content. Search results do not currently include matching-text snippets.

## License

MIT. See [LICENSE](LICENSE).
