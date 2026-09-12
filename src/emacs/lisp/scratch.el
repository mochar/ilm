;; -*- lexical-binding: t; -*-

(load-file "./ilm.el")

(ilm--reload-module)

(let ((data-dir "/home/mochar/tmp/ilm/"))
  ;; (delete-directory data-dir t)
  ;; (make-directory data-dir)
  (ilm-core-init data-dir))

;; org-ilm concepts
(let ((concepts nil))
  (org-ql-select (list "~/org/concepts.org")
    `(and (property "ID"))
    :action
    (lambda ()
      (when-let* ((org-id (org-id-get))
                  (heading (org-get-heading t t t t))
                  (id (ilm-add-concept heading)))
        (push (cons org-id id) concepts))))
  (dolist (concept concepts)
    (dolist (child (org-ilm--concepts-descendants (car concept) 'main))
      (when-let* ((child-id (map-elt concepts child)))
        (ignore-errors
            (ilm-add-concept-parents child-id (cdr concept)))))))

(let* ((c (seq-find
           (lambda (c) (string= "Half-cauchy factorization" (map-elt c :name)))
           (ilm--all-concepts))))
  (ilm-insert-concept-graph c))
#

