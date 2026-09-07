;;; ilm.el --- ilm -*- lexical-binding: t -*-

;;; Commentary:

;; ilm

;;; Code:

;;;; Requires

(require 'cl-lib)
(require 'map)

;;;; Module

(defun ilm--reload-module ()
  "Hack that copies the so file to a unique name and loads that as a module.
Note that this does not unload the previous loaded objects."
  (let ((tmp (make-temp-file "ilm_el_" nil ".so")))
    (copy-file "../zig-out/lib/ilm-core.so" tmp t)
    (module-load tmp)))

;;;; Core

(defvar ilm--core nil
  "Pointer to the internal Core struct.")

(defun ilm-core-init (data-dir)
  (setq ilm--core (ilm--core-init data-dir)))

(defun ilm-core-ensure ()
  "Raises an error if `ilm--core' not set or invalid, otherwise return it."
  (unless ilm--core
    (error "Ilm core invalid: not initialized"))
  (unless (ilm--core-is-valid ilm--core)
    (error "Ilm core invalid: state invalid"))
  ilm--core)

;;;; Concepts

;; TODO Concept cache, just store all concepts in a var

(defun ilm-add-concept (name &optional parent-ids)
  (ilm-core-ensure)
  (ilm--core-add-concept ilm--core name parent-ids))

(defun ilm--all-concepts ()
  (ilm-core-ensure)
  (ilm--core-all-concepts ilm--core))

(defun ilm--select-concept ()
  (ilm-core-ensure)
  (let* ((concepts (ilm--core-all-concepts ilm--core))
         (options (mapcar (lambda (concept)
                            (map-let (:name :id) concept
                              (propertize
                               ;; Invisible suffix ensures candidates with
                               ;; identical names are unique strings.
                               (concat name (propertize (format " #%s" id) 'invisible t))
                               'concept concept)))
                          concepts)))
    (consult--read
     options
     :prompt "Concepts: "
     :annotate (lambda (option)
                 (let ((c (get-text-property 0 'concept option)))
                   (format " %s" (map-elt c :id))))
     :lookup
     (lambda (selected candidates &rest _)
       (consult--lookup-prop 'concept selected candidates)))))

(defun ilm-concepts-by-ids (ids)
  (ilm-core-ensure)
  (ilm--core-concepts-by-id ilm--core ids))

(defun ilm-concept-ancestors (ids &optional direct-only)
  "Return the ancestors of concept IDS.
If DIRECT-ONLY is non-nil, only return direct parents.
Otherwise return the full hierarchy with :is_direct and :depth properties."
  (ilm-core-ensure)
  (let ((ids-list (ensure-list ids)))
    (ilm--core-ancestors ilm--core ids-list (if direct-only t nil))))

(defun ilm-concept-parents (ids)
  "Return only direct parents of concept IDS."
  (ilm-concept-ancestors ids t))

;;;; Footer

(provide 'ilm)

;;; ilm.el ends here
