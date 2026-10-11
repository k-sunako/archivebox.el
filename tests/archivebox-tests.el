;;; archivebox-tests.el --- Tests for ArchiveBox search -*- lexical-binding: t; -*-

(require 'ert)
(require 'archivebox)

(ert-deftest archivebox-tests-encodes-search-query-and-offset ()
  (let ((url (archivebox--api-url "日本語 & Emacs" "contents" 50)))
    (should (string-match-p "%E6%97%A5" url))
    (should (string-match-p "%26" url))
    (should (string-match-p "search_mode=contents" url))
    (should (string-match-p "offset=50" url))))

(ert-deftest archivebox-tests-parses-paginated-results ()
  (let* ((response
          '((items . (((id . "snap-1")
                       (title . "日本語 title")
                       (url . "https://example.org/")
                       (tags . ("elisp" "read"))
                       (status . "sealed")
                       (created_at . "2026-10-11T08:00:00Z"))))
            (total_items . 23)
            (limit . 1)
            (offset . 0)))
         (items (archivebox--response-items response)))
    (should (= (length items) 1))
    (should (= (archivebox--response-total response items) 23))
    (should (equal (archivebox--snapshot-title (car items)) "日本語 title"))
    (should (equal (archivebox--clean-string '("elisp" "read")) "elisp, read"))))

(ert-deftest archivebox-tests-callback-parses-http-response-buffer ()
  (let ((results (get-buffer-create " *ArchiveBox test results*"))
        (response (get-buffer-create " *ArchiveBox test HTTP response*")))
    (unwind-protect
        (progn
          (with-current-buffer results
            (archivebox-search-mode)
            (setq archivebox--request-id 7))
          (with-current-buffer response
            (erase-buffer)
            (insert "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
                    "{\"items\":[{\"id\":\"snap-1\",\"title\":\"Emacs Primer\",\"url\":\"https://example.org/\",\"tags\":[\"elisp\"],\"status\":\"sealed\"}],\"total_items\":1}")
            (setq-local url-http-response-status 200)
            (setq-local url-http-end-of-headers
                        (copy-marker (save-excursion
                                       (goto-char (point-min))
                                       (search-forward "\r\n\r\n")
                                       (point))))
            (archivebox--request-callback results "emacs" "contents" 0 7 nil))
          (with-current-buffer results
            (should (= (length archivebox--items) 1))
            (should (equal (archivebox--snapshot-title (car archivebox--items))
                           "Emacs Primer"))
            (should (= archivebox--total 1))))
      (when (buffer-live-p results) (kill-buffer results))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest archivebox-tests-search-buffer-keybindings ()
  (with-temp-buffer
    (archivebox-search-mode)
    (should (eq (lookup-key archivebox-search-mode-map (kbd "RET"))
                #'archivebox-search-open-snapshot))
    (should (eq (lookup-key archivebox-search-mode-map (kbd "n"))
                #'archivebox-search-next-page))))

(ert-run-tests-batch-and-exit)

;;; archivebox-tests.el ends here
