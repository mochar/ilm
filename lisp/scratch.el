;; -*- lexical-binding: t; -*-

(load-file "./ilm.el")

(ilm--reload-module)

(setq ilm-state (ilm--core-init "/home/mochar/tmp/ilm/")) 

(ilm--core-new-id ilm-state)
(ilm--core-add-concept ilm-state "lol")
