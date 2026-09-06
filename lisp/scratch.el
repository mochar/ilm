;; -*- lexical-binding: t; -*-

(load-file "./ilm.el")

(ilm--reload-module)

(ilm-core-init "/home/mochar/tmp/ilm/")

(ilm--core-new-id ilm--core)
(ilm--core-add-concept ilm--core "lol")

(ilm--all-concepts)

(ilm--select-concept)

