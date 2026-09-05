;; -*- lexical-binding: t; -*-

(load-file "./ilm.el")

(ilm--reload-module)

(setq ilm-state (ilm--init "/home/mochar/tmp/ilm/")) 

(ilm--new-id ilm-state)
(ilm--add-concept ilm-state "keklol")
