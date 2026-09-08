;; -*- lexical-binding: t; -*-

(load-file "./ilm.el")

(ilm--reload-module)

(let ((data-dir "/home/mochar/tmp/ilm/"))
  ;; (delete-directory data-dir t)
  ;; (make-directory data-dir)
  (ilm-core-init data-dir))

(let* ((a (ilm-add-concept "A"))
       (b (ilm-add-concept "B" (list a)))
       (c (ilm-add-concept "C" (list a b))))
  (message "A: %s" (ilm-concept-ancestors a))
  (message "B: %s" (ilm-concept-ancestors b))
  (message "C: %s" (ilm-concept-ancestors c)))


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

;; Half-cauchy factorization
(ilm--concept-ancestors)

(setq ilm-concept (seq-find (lambda (c) (string= "Half-cauchy factorization" (map-elt c :name))) (ilm--all-concepts)))
;; (:id "01a079b6-c981-7b96-a568-eee965f36206" :name "Half-cauchy factorization")
(ilm-concept-ancestors (map-elt ilm-concept :id))
;; ((:id "01a079b6-c961-74d7-9672-d3f89e73dd8b" :name "Bayesian statistics" :child_id "01a079b6-c981-7b96-a568-eee965f36206" :depth 1 :is_direct t) (:id "01a079b6-c97f-7848-b6c2-c6c9fc38b884" :name "Half-cauchy" :child_id "01a079b6-c981-7b96-a568-eee965f36206" :depth 1 :is_direct t) (:id "01a079b6-c97c-75b6-91b8-2f36952fcec2" :name "Distributions" :child_id "01a079b6-c981-7b96-a568-eee965f36206" :depth 2 :is_direct nil) (:id "01a079b6-c95c-79ce-a51f-7e3a7d477acf" :name "Statistics" :child_id "01a079b6-c981-7b96-a568-eee965f36206" :depth 2 :is_direct nil))

(package-vc-install (cons 'dag-draw '(:url "https://codeberg.org/Trevoke/dag-draw.el" :rev :newest)))
(require 'dag-draw)

(let* ((c (seq-find (lambda (c) (string= "Half-cauchy factorization" (map-elt c :name))) (ilm--all-concepts)))
       (as (ilm-concept-ancestors (map-elt c :id)))
       (g (dag-draw-create-graph)))
  (dag-draw-add-node g (intern (map-elt c :id)) (map-elt c :name))
  (dolist (a as)
    (dag-draw-add-node g (intern (map-elt a :id)) (map-elt a :name))
    (dag-draw-add-edge g (intern (map-elt a :child_id)) (intern (map-elt a :id))))
  (dag-draw-layout-graph g)
  (princ (dag-draw-render-graph g 'ascii (intern (map-elt c :id)))))
╔════════════════════════╗
║Half-cauchy factorizatio║
╚════════════╦═══════════╝
             │
             ├────────────────────┬─────────────────────┬─────────────────────┐
┌────────────▼────────┐    ┌──────▼──────┐      ┌───────▼───────┐      ┌──────▼─────┐
│ Bayesian statistics │    │ Half-cauchy │      │ Distributions │      │ Statistics │
└─────────────────────┘    └─────────────┘      └───────────────┘      └────────────┘"
