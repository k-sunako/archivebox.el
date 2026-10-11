;;; archivebox.el --- Search an ArchiveBox collection from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 砂子和正
;; Author: 砂子和正
;; Version: 0.1
;; Package-Requires: ((emacs "27.1"))
;; Keywords: archive, web, search

;;; Commentary:
;; Read-only ArchiveBox snapshot search using its REST API.
;; The API token is read from auth-source; never put it in this file or in a URL.
;;
;; Add an entry to ~/.authinfo (chmod 600), replacing YOUR_API_TOKEN locally:
;; machine 127.0.0.1 port 8000 login archivebox password YOUR_API_TOKEN
;;
;; Then run M-x archivebox-search.

;;; Code:

(require 'auth-source)
(require 'browse-url)
(require 'json)
(require 'tabulated-list)
(require 'url)
(require 'url-http)
(require 'url-util)
(require 'subr-x)

(defgroup archivebox nil
  "Search an ArchiveBox collection from Emacs."
  :group 'tools
  :prefix "archivebox-")

(defcustom archivebox-base-url "http://127.0.0.1:8000"
  "Base URL of the ArchiveBox web interface, without a trailing slash."
  :type 'string
  :group 'archivebox)

(defcustom archivebox-api-host "127.0.0.1"
  "Host name used to find the API token in `auth-source'."
  :type 'string
  :group 'archivebox)

(defcustom archivebox-api-port "8000"
  "Port used to find the API token in `auth-source'."
  :type 'string
  :group 'archivebox)

(defcustom archivebox-api-user "archivebox"
  "Login name used to find the API token in `auth-source'."
  :type 'string
  :group 'archivebox)

(defcustom archivebox-search-mode "contents"
  "Default ArchiveBox search mode."
  :type '(choice (const "meta") (const "contents") (const "deep"))
  :group 'archivebox)

(defcustom archivebox-page-size 50
  "Number of snapshots requested in each page."
  :type 'integer
  :group 'archivebox)

(defcustom archivebox-snapshot-url-function #'archivebox-default-snapshot-url
  "Function mapping an API snapshot object to its ArchiveBox UI URL.

The default builds a Django admin change-page URL.  If your ArchiveBox
version uses another route, customize this function.  The API response's
`url' field is the original page URL; press `o' in the results buffer to
open that URL instead."
  :type 'function
  :group 'archivebox)

(defconst archivebox--buffer-name "*ArchiveBox Search*")
(defvar archivebox--last-query "")

(defvar-local archivebox--query nil)
(defvar-local archivebox--mode nil)
(defvar-local archivebox--offset 0)
(defvar-local archivebox--total nil)
(defvar-local archivebox--items nil)
(defvar-local archivebox--items-by-id nil)
(defvar-local archivebox--request-id 0)

(defun archivebox-default-snapshot-url (snapshot)
  "Build a likely ArchiveBox admin URL for SNAPSHOT.

If the route differs on a particular ArchiveBox deployment, customize
`archivebox-snapshot-url-function'."
  (let ((id (archivebox--object-get snapshot 'id)))
    (unless id
      (user-error "This API result has no snapshot id"))
    (format "%s/admin/core/snapshot/%s/change/"
            (string-remove-suffix "/" archivebox-base-url)
            (url-hexify-string (format "%s" id)))))

(defun archivebox--object-get (object key)
  "Get KEY from JSON OBJECT, accepting alists and hash tables."
  (let ((string-key (symbol-name key)))
    (cond
     ((hash-table-p object)
      (or (gethash key object) (gethash string-key object)))
     ((listp object)
      (or (alist-get key object)
          (alist-get string-key object nil nil #'equal)))
     (t nil))))

(defun archivebox--auth-token ()
  "Return the API token from `auth-source', or signal a helpful error."
  ;; Prioritize the plain, permission-restricted file regardless of whether
  ;; the current Emacs session has reloaded `myinit.org' yet.
  (let* ((auth-sources (cons (expand-file-name "~/.authinfo") auth-sources))
         (found (car (auth-source-search
                      :host archivebox-api-host
                      :port archivebox-api-port
                      :user archivebox-api-user
                      :require '(:secret)
                      :max 1)))
         (secret (plist-get found :secret))
         (token (if (functionp secret) (funcall secret) secret)))
    (unless (and (stringp token) (not (string-empty-p token)))
      (user-error
       (concat "No ArchiveBox API token found in ~/.authinfo.  Add an entry for "
               "host %s, port %s, login %s")
       archivebox-api-host archivebox-api-port archivebox-api-user))
    token))

(defun archivebox--api-url (query mode offset)
  "Build the snapshots API URL for QUERY, MODE, and OFFSET."
  (let ((api-root (concat (string-remove-suffix "/" archivebox-base-url)
                          "/api/v1/core/snapshots")))
    (format "%s?search=%s&search_mode=%s&limit=%s&offset=%s"
            api-root
            (url-hexify-string query)
            (url-hexify-string mode)
            archivebox-page-size
            offset)))

(defun archivebox--clean-string (value)
  "Convert JSON VALUE to a single-line display string."
  (cond
   ((null value) "")
   ((eq value :false) "")
   ((stringp value) (replace-regexp-in-string "[\n\r\t]+" " " value))
   ((listp value)
    (mapconcat #'archivebox--clean-string value ", "))
   (t (format "%s" value))))

(defun archivebox--snapshot-date (snapshot)
  "Return a concise date string for SNAPSHOT."
  (let ((date (or (archivebox--object-get snapshot 'bookmarked_at)
                  (archivebox--object-get snapshot 'created_at)
                  (archivebox--object-get snapshot 'timestamp))))
    (let ((text (archivebox--clean-string date)))
      (if (> (length text) 19) (substring text 0 19) text))))

(defun archivebox--snapshot-title (snapshot)
  "Return a useful display title for SNAPSHOT."
  (let ((title (archivebox--clean-string
                (archivebox--object-get snapshot 'title)))
        (url (archivebox--clean-string
              (archivebox--object-get snapshot 'url))))
    (if (string-empty-p title)
        (if (string-empty-p url) "(untitled)" url)
      title)))

(defun archivebox--response-items (json-object)
  "Extract snapshots from JSON-OBJECT in common API response formats."
  (let ((items (or (archivebox--object-get json-object 'items)
                   (archivebox--object-get json-object 'results))))
    (cond
     ((vectorp items) (append items nil))
     ((listp items) items)
     ((vectorp json-object) (append json-object nil))
     ((and (listp json-object)
           (or (null json-object)
               (not (and (consp (car json-object))
                         (or (symbolp (caar json-object))
                             (stringp (caar json-object)))))))
      json-object)
     (t nil))))

(defun archivebox--response-total (json-object items)
  "Return total matching item count in JSON-OBJECT, or nil if unknown."
  (or (archivebox--object-get json-object 'total_items)
      (archivebox--object-get json-object 'total)
      (archivebox--object-get json-object 'count)
      (length items)))

(defun archivebox--http-error-message (status response-code body)
  "Return a helpful error message for STATUS, RESPONSE-CODE, and BODY."
  (let* ((detail (or (archivebox--object-get body 'detail)
                     (archivebox--object-get body 'message)
                     (archivebox--object-get body 'error)))
         (detail-text (archivebox--clean-string detail)))
    (cond
     ((plist-get status :error)
      (format "ArchiveBox connection failed: %s" (plist-get status :error)))
     ((= response-code 401)
      "ArchiveBox rejected the API token (HTTP 401). Check/replace the auth-source entry.")
     ((= response-code 403)
      "ArchiveBox denied this API request (HTTP 403). Check the account permissions.")
     ((not (and (>= response-code 200) (< response-code 300)))
      (format "ArchiveBox API returned HTTP %s%s"
              response-code
              (if (string-empty-p detail-text) ""
                (concat ": " detail-text))))
     (t (format "Could not read ArchiveBox response%s"
                (if (string-empty-p detail-text) ""
                  (concat ": " detail-text)))))))

(defun archivebox--set-buffer-message (buffer text)
  "Show TEXT in BUFFER's header line and echo area."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq header-line-format text))
    (message "%s" text)))

(defun archivebox--request-callback (buffer query mode offset request-id status)
  "Handle asynchronous API response for BUFFER and REQUEST-ID."
  (let* ((response-buffer (current-buffer))
         (response-code (or (and (boundp 'url-http-response-status)
                                 url-http-response-status)
                            0))
         (response-body
          (with-current-buffer response-buffer
            (goto-char (or (and (boundp 'url-http-end-of-headers)
                                url-http-end-of-headers)
                           (point-min)))
            (buffer-substring-no-properties (point) (point-max)))))
    (unwind-protect
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (= request-id archivebox--request-id)
            (let ((json-object nil)
                  (parse-error nil))
              (unless (or (plist-get status :error)
                          (string-empty-p (string-trim response-body)))
                (condition-case err
                    (setq json-object
                          (json-parse-string response-body
                                             :object-type 'alist
                                             :array-type 'list
                                             :null-object nil
                                             :false-object :false))
                  (error (setq parse-error err))))
              (if (or (plist-get status :error)
                      (not (and (>= response-code 200)
                                (< response-code 300)))
                      parse-error
                      (string-empty-p (string-trim response-body)))
                  (let ((text (cond
                               (parse-error
                                (format "Could not parse ArchiveBox JSON (HTTP %s, %d-byte body): %s"
                                        response-code (string-bytes response-body)
                                        (error-message-string parse-error)))
                               ((string-empty-p (string-trim response-body))
                                (format "ArchiveBox returned an empty response body (HTTP %s)."
                                        response-code))
                               (t (archivebox--http-error-message
                                   status response-code json-object)))))
                    (setq tabulated-list-entries nil)
                    (tabulated-list-print t)
                    (archivebox--set-buffer-message buffer text))
                (let* ((items (archivebox--response-items json-object))
                       (total (archivebox--response-total json-object items)))
                  (setq archivebox--query query
                        archivebox--mode mode
                        archivebox--offset offset
                        archivebox--total total
                        archivebox--items items
                        archivebox--items-by-id (make-hash-table :test #'equal))
                  (setq tabulated-list-entries
                        (mapcar
                         (lambda (item)
                           (let* ((id (archivebox--clean-string
                                       (or (archivebox--object-get item 'id)
                                           (archivebox--object-get item 'url))))
                                  (title (archivebox--snapshot-title item))
                                  (url (archivebox--clean-string
                                        (archivebox--object-get item 'url)))
                                  (date (archivebox--snapshot-date item))
                                  (tags (archivebox--clean-string
                                         (archivebox--object-get item 'tags)))
                                  (state (archivebox--clean-string
                                          (archivebox--object-get item 'status))))
                             (puthash id item archivebox--items-by-id)
                             (list id (vector title url date tags state))))
                         items))
                  (setq header-line-format
                        (format "Query: %s   Mode: %s   %d result(s)   Offset: %d"
                                query mode total offset))
                  (tabulated-list-print t)
                  (when (null items)
                    (message "ArchiveBox: no matching snapshots"))))))))
    (when (buffer-live-p response-buffer)
      (kill-buffer response-buffer)))))

(defun archivebox--request (query mode offset)
  "Request page at OFFSET for QUERY and MODE."
  (let* ((buffer (get-buffer-create archivebox--buffer-name))
         (token (archivebox--auth-token))
         (url (archivebox--api-url query mode offset)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'archivebox-search-mode)
        (archivebox-search-mode))
      (setq archivebox--request-id (1+ archivebox--request-id))
      (let ((request-id archivebox--request-id))
        (setq archivebox--query query
              archivebox--mode mode
              archivebox--offset offset
              header-line-format (format "Searching ArchiveBox for: %s …" query))
        (message "Searching ArchiveBox for: %s …" query)
        (let ((url-request-method "GET")
              (url-request-extra-headers
               `(("Accept" . "application/json")
                 ("Authorization" . ,(concat "Bearer " token)))))
          (url-retrieve
           url
           (apply-partially #'archivebox--request-callback
                            buffer query mode offset request-id)
           nil t t))))))

(defun archivebox-search (&optional query mode)
  "Search ArchiveBox for QUERY using MODE and display the results.

Interactively, prompt for a query and search mode."
  (interactive)
  (let* ((query (or query
                    (read-string "Search ArchiveBox: " archivebox--last-query)))
         (mode (or mode
                   (completing-read
                    (format "Search mode (default %s): " archivebox-search-mode)
                    '("meta" "contents" "deep") nil t nil nil
                    archivebox-search-mode))))
    (unless (string-match-p "\\`\\(meta\\|contents\\|deep\\)\\'" mode)
      (user-error "Unsupported ArchiveBox search mode: %s" mode))
    (when (string-empty-p query)
      (user-error "Search query must not be empty"))
    (setq archivebox--last-query query)
    (archivebox--request query mode 0)
    (pop-to-buffer archivebox--buffer-name)))

(defun archivebox-search-refresh ()
  "Repeat the current ArchiveBox search from the first page."
  (interactive)
  (unless (and archivebox--query archivebox--mode)
    (user-error "No ArchiveBox search to refresh"))
  (archivebox--request archivebox--query archivebox--mode 0))

(defun archivebox-search-again ()
  "Prompt for another query, preserving the current search mode."
  (interactive)
  (unless archivebox--mode
    (user-error "No ArchiveBox search mode selected"))
  (archivebox-search nil archivebox--mode))

(defun archivebox-search-change-mode ()
  "Change the search mode and repeat the current ArchiveBox query."
  (interactive)
  (unless archivebox--query
    (user-error "No ArchiveBox search to change"))
  (let ((mode (completing-read "Search mode: "
                               '("meta" "contents" "deep") nil t nil nil
                               archivebox--mode)))
    (archivebox--request archivebox--query mode 0)))

(defun archivebox-search-next-page ()
  "Show the next page of ArchiveBox search results."
  (interactive)
  (unless archivebox--query
    (user-error "No ArchiveBox search to paginate"))
  (let ((next (+ archivebox--offset archivebox-page-size)))
    (if (or (and (numberp archivebox--total) (< next archivebox--total))
            (= (length archivebox--items) archivebox-page-size))
        (archivebox--request archivebox--query archivebox--mode next)
      (user-error "Already at the last ArchiveBox page"))))

(defun archivebox-search-previous-page ()
  "Show the previous page of ArchiveBox search results."
  (interactive)
  (unless archivebox--query
    (user-error "No ArchiveBox search to paginate"))
  (if (> archivebox--offset 0)
      (archivebox--request archivebox--query archivebox--mode
                           (max 0 (- archivebox--offset archivebox-page-size)))
    (user-error "Already at the first ArchiveBox page")))

(defun archivebox-search--selected-snapshot ()
  "Return the snapshot at point, or signal a user error."
  (let* ((id (tabulated-list-get-id))
         (item (and id archivebox--items-by-id
                    (gethash id archivebox--items-by-id))))
    (unless item
      (user-error "No ArchiveBox result on this line"))
    item))

(defun archivebox-search-open-snapshot ()
  "Open the selected snapshot's ArchiveBox UI page."
  (interactive)
  (let ((url (funcall archivebox-snapshot-url-function
                      (archivebox-search--selected-snapshot))))
    (browse-url url)))

(defun archivebox-search-open-original ()
  "Open the selected snapshot's original URL."
  (interactive)
  (let ((url (archivebox--object-get
              (archivebox-search--selected-snapshot) 'url)))
    (unless (and (stringp url) (not (string-empty-p url)))
      (user-error "This ArchiveBox result has no original URL"))
    (browse-url url)))

(define-derived-mode archivebox-search-mode tabulated-list-mode "ArchiveBox"
  "Major mode for viewing ArchiveBox search results."
  (setq tabulated-list-format
        [ ("Title" 34 t)
          ("URL" 48 t)
          ("Saved" 19 t)
          ("Tags" 24 t)
          ("Status" 12 t) ])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Saved" t))
  (tabulated-list-init-header)
  (setq-local truncate-lines t)
  (setq-local archivebox--offset 0)
  (setq-local archivebox--total nil)
  (setq-local archivebox--items nil)
  (setq-local archivebox--items-by-id (make-hash-table :test #'equal))
  (let ((map archivebox-search-mode-map))
    (define-key map (kbd "RET") #'archivebox-search-open-snapshot)
    (define-key map (kbd "o") #'archivebox-search-open-original)
    (define-key map (kbd "g") #'archivebox-search-refresh)
    (define-key map (kbd "s") #'archivebox-search-again)
    (define-key map (kbd "m") #'archivebox-search-change-mode)
    (define-key map (kbd "n") #'archivebox-search-next-page)
    (define-key map (kbd "p") #'archivebox-search-previous-page)
    (define-key map (kbd "q") #'quit-window)))

(provide 'archivebox)

;;; archivebox.el ends here
