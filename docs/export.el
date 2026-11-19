;;; export.el --- Publish docs/orgmode to docs/source -*- lexical-binding: t; -*-

;; Run from docs/:  emacs -Q --batch --load export.el
;;
;; Every .org page under orgmode/ becomes a .rst page under source/ at the
;; same path; images are copied beside them.  A page that fails to export
;; fails the run.
;;
;; ox-rst is GPL-2+ and is not stored in the tree.  The pinned upstream
;; commit is fetched into a cache outside it ($STACKHANDS_OX_RST_CACHE, else
;; $XDG_CACHE_HOME/stackhands-docs/ox-rst/<commit>/), its sha256 checked, and
;; that file loaded.
;;
;; Org 9.7 stores the text of ~code~ and =verbatim= as a deferred value,
;; which ox-rst passes to replace-regexp-in-string; deferred values are
;; resolved on the parse tree before any transcoder runs.
;;
;; Links between pages are written as Org file links and come out as :doc:
;; roles.  These link types write the other Sphinx roles:
;;
;;   [[zig:zig_common.proc.run]]        :zig:obj:`zig_common.proc.run`
;;   [[autodoc:zig_common.proc]]        :zig:autodoc:`zig_common.proc`
;;   [[autodoc:/][Zig autodoc]]         the autodoc site's front page
;;   [[py:eessi_arch_guard.decide]]     :py:obj:`eessi_arch_guard.decide`
;;   [[rust:struct:eb_stack::Plan]]     :rust:struct:`eb_stack::Plan`
;;   [[site:eb-local:howto/index]]      :external+eb-local:doc:`howto/index`
;;   [[man:bwrap(1)]]                   :manpage:`bwrap(1)`
;;   [[term:EESSI]]                     :term:`EESSI`
;;
;; A description, [[zig:zig_common.proc.run][run]], becomes the link text.

(require 'org)
(require 'ox-publish)

(defconst stackhands-ox-rst-revision
  "b73eff187eebac24b457688bfd27f09eff434860")
(defconst stackhands-ox-rst-sha256
  "17ac300861f22e62166785a8ac1b97d32bb8a131ee5ba1b7a9db8977b07e7ede")
(defconst stackhands-ox-rst-url
  (concat "https://raw.githubusercontent.com/msnoigrs/ox-rst/"
          stackhands-ox-rst-revision
          "/ox-rst.el"))

(defvar stackhands-export-failures nil
  "Alist of (file . message) for pages that failed to publish.")

(defun stackhands-export-fail (format-string &rest args)
  "Print FORMAT-STRING with ARGS and exit non-zero."
  (apply #'message format-string args)
  (kill-emacs 1))

(defun stackhands-ox-rst-cache-file ()
  "Absolute path of the pinned ox-rst source, outside the repository."
  (expand-file-name
   (concat stackhands-ox-rst-revision "/ox-rst.el")
   (or (getenv "STACKHANDS_OX_RST_CACHE")
       (expand-file-name
        "stackhands-docs/ox-rst"
        (or (getenv "XDG_CACHE_HOME")
            (expand-file-name ".cache"
                              (or (getenv "HOME")
                                  temporary-file-directory)))))))

(defun stackhands-file-sha256 (file)
  "Return the sha256 hex digest of FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun stackhands-fetch-ox-rst (dest)
  "Download the pinned ox-rst to DEST, or exit non-zero."
  (let ((part (concat dest ".partial")))
    (make-directory (file-name-directory dest) t)
    (when (file-exists-p part)
      (delete-file part))
    (message "export: fetching ox-rst %s" stackhands-ox-rst-revision)
    (let ((status (call-process "curl" nil nil nil
                                "-fsSL" "--retry" "3" "--retry-delay" "1"
                                "-o" part stackhands-ox-rst-url)))
      (unless (and (eq status 0) (file-readable-p part))
        (when (file-exists-p part)
          (delete-file part))
        (stackhands-export-fail "export failed: could not fetch %s (curl exited %s)"
                                stackhands-ox-rst-url status)))
    (let ((got (stackhands-file-sha256 part)))
      (unless (string= got stackhands-ox-rst-sha256)
        (delete-file part)
        (stackhands-export-fail "export failed: ox-rst checksum mismatch (expected %s, got %s)"
                                stackhands-ox-rst-sha256 got)))
    (rename-file part dest t)))

(let ((dest (stackhands-ox-rst-cache-file)))
  (unless (and (file-readable-p dest)
               (string= (stackhands-file-sha256 dest) stackhands-ox-rst-sha256))
    (stackhands-fetch-ox-rst dest))
  ;; NOSUFFIX, so a stale ox-rst.elc beside it is never loaded.
  (load dest nil nil t))

(message "export: Org %s; ox-rst %s" (org-version) stackhands-ox-rst-revision)

;; Source blocks are shown, never run.
(setq org-export-use-babel nil)
;; x86_64 and EESSI_USER_INSTALL are names, not subscripts; only _{...} and
;; ^{...} are.
(setq org-export-with-sub-superscripts '{})

(defun stackhands-resolve-deferred (tree _backend _info)
  "Replace deferred properties in TREE with their values."
  (when (fboundp 'org-element-properties-resolve)
    (org-element-map tree t
      (lambda (node)
        (unless (stringp node)
          (org-element-properties-resolve node t)))))
  tree)

(add-to-list 'org-export-filter-parse-tree-functions #'stackhands-resolve-deferred)

;; ox-rst writes a link to another Org page as a link to its .rst file, and
;; leaves a link to a generated .md page as it is; Sphinx needs a :doc: role
;; to reach either rendered page.
(defun stackhands-doc-link-filter (text backend _info)
  (if (org-export-derived-backend-p backend 'rst)
      (replace-regexp-in-string
       "`\\([^`]+\\) <\\([^>:]+\\)\\.\\(rst\\|md\\)>`_"
       ":doc:`\\1 <\\2>`"
       text)
    text))

(add-to-list 'org-export-filter-link-functions #'stackhands-doc-link-filter)

(defun stackhands-role (role target desc)
  "The Sphinx ROLE for TARGET, with DESC as its text when given."
  (if (and desc (not (string-empty-p desc)) (not (string= desc target)))
      (format ":%s:`%s <%s>`" role desc target)
    (format ":%s:`%s`" role target)))

(defun stackhands-define-role-link (type role-fn)
  "Make Org links of TYPE export to the role ROLE-FN returns for their path."
  (org-link-set-parameters
   type
   :export (lambda (path desc backend &optional _info)
             (if (org-export-derived-backend-p backend 'rst)
                 (let ((role-target (funcall role-fn path)))
                   (stackhands-role (car role-target) (cdr role-target) desc))
               (or desc path)))))

(stackhands-define-role-link "zig" (lambda (path) (cons "zig:obj" path)))
(stackhands-define-role-link "autodoc" (lambda (path) (cons "zig:autodoc" path)))
(stackhands-define-role-link "py" (lambda (path) (cons "py:obj" path)))
(stackhands-define-role-link "man" (lambda (path) (cons "manpage" path)))
(stackhands-define-role-link "term" (lambda (path) (cons "term" path)))
;; A heading on another page, by the CUSTOM_ID ox-rst writes as its label.
(stackhands-define-role-link "ref" (lambda (path) (cons "ref" path)))
(stackhands-define-role-link
 "rust" (lambda (path)
          ;; rust:struct:a::B names the role; rust:anyhow::Error does not.
          (if (string-match "\\`\\([a-z]+\\):\\([^:].*\\)\\'" path)
              (cons (concat "rust:" (match-string 1 path)) (match-string 2 path))
            (cons "rust:any" path))))
(stackhands-define-role-link
 "site" (lambda (path)
          (unless (string-match "\\`\\([^:]+\\):\\(.+\\)\\'" path)
            (error "site link needs SITE:PAGE, got %s" path))
          (cons (format "external+%s:doc" (match-string 1 path)) (match-string 2 path))))

(setq org-publish-project-alist
      '(("sphinx-rst"
         :base-directory "./orgmode/"
         :base-extension "org"
         :publishing-directory "./source/"
         :publishing-function org-rst-publish-to-rst
         :recursive t
         :headline-levels 4
         :with-toc nil
         :section-numbers nil)
        ("sphinx-images"
         :base-directory "./orgmode/"
         :base-extension "svg\\|png\\|jpg\\|jpeg\\|webp"
         :publishing-directory "./source/"
         :publishing-function org-publish-attachment
         :recursive t)
        ("sphinx" :components ("sphinx-rst" "sphinx-images"))))

(defun stackhands-publish-file (orig filename &optional project no-cache)
  "Call ORIG to publish FILENAME, recording a failure instead of stopping."
  (condition-case err
      (funcall orig filename project no-cache)
    (error
     (let ((msg (error-message-string err)))
       (message "export failed: %s: %s" filename msg)
       (push (cons filename msg) stackhands-export-failures)
       nil))))

(advice-add 'org-publish-file :around #'stackhands-publish-file)

;; Every .rst under source/ is an export, so one whose page was renamed or
;; deleted would otherwise stay in the build.
(dolist (stale (directory-files-recursively "./source/" "\\.rst\\'"))
  (delete-file stale))

(org-publish "sphinx" t)

(when stackhands-export-failures
  (message "export: %d page(s) failed" (length stackhands-export-failures))
  (dolist (fail (nreverse stackhands-export-failures))
    (message "export failed: %s: %s" (car fail) (cdr fail)))
  (kill-emacs 1))
