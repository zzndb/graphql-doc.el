;;; graphql-doc.el --- GraphQL Doc -*- lexical-binding: t -*-

;; Copyright (c) 2021 Ian Fitzpatrick <itfitzpatrick@gmail.com>

;; URL: https://github.com/ifitzpatrick/graphql-doc
;;
;; This file is not part of GNU Emacs.
;;
;;; License: GPLv3

;; Author: Ian Fitzpatrick
;; Created: April 25, 2021
;; Package-Version: 0.0.1
;; Package-Requires: ((emacs "25.1") (request "0.3.2") (promise "1.1"))

;;; Commentary:
;; GraphQL Documentation explorer

;;; Code:

(require 'cl-lib)
(require 'promise)
(require 'request)

(defvar graphql-doc--introspection-query
"query IntrospectionQuery {
  __schema {
    queryType { name }
    mutationType { name }
    subscriptionType { name }
    types {
      ...FullType
    }
    directives {
      name
      description
      
      locations
      args {
        ...InputValue
      }
    }
  }
}

fragment FullType on __Type {
  kind
  name
  description
  
  fields(includeDeprecated: true) {
    name
    description
    args {
      ...InputValue
    }
    type {
      ...TypeRef
    }
    isDeprecated
    deprecationReason
  }
  inputFields {
    ...InputValue
  }
  interfaces {
    ...TypeRef
  }
  enumValues(includeDeprecated: true) {
    name
    description
    isDeprecated
    deprecationReason
  }
  possibleTypes {
    ...TypeRef
  }
}

fragment InputValue on __InputValue {
  name
  description
  type { ...TypeRef }
  defaultValue
}

fragment TypeRef on __Type {
  kind
  name
  ofType {
    kind
    name
    ofType {
      kind
      name
      ofType {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType {
                kind
                name
              }
            }
          }
        }
      }
    }
  }
}")

(defun graphql-doc--request (url data headers)
  "GraphQL request to URL with DATA and HEADERS."
  (promise-new
   (lambda (resolve reject)
     (request
       url
       :type "POST"
       :parser 'json-read
       :data
       data
       :headers
       headers
       :error
       (cl-function
        (lambda (&key response &allow-other-keys)
          (funcall reject (request-response-data response))))
       :success
       (cl-function
        (lambda (&key response &allow-other-keys)
          (funcall resolve (request-response-data response))))))))

(defvar-local graphql-doc--introspection-results nil)

(defun graphql-doc--request-introspection (api)
  "Request introspection query from API."
  (promise-chain
      (graphql-doc--request
       (plist-get api :url)
       (append
        (plist-get api :data)
        `(("variables" . "")
          ("query" . ,graphql-doc--introspection-query)))
       (plist-get api :headers))
    (then (lambda (data)
            (setq-local graphql-doc--introspection-results data)))
    (promise-catch (lambda (data)
                     (message "error: %s" data)))))

(defcustom graphql-doc-apis nil
  "Alist mapping name to an api plist."
  :group 'graphql-doc
  :type '(alist))

(defun graphql-doc-add-api (name api)
  "Add an entry (NAME . API) to apis alist."
  (add-to-list 'graphql-doc-apis `(,name . ,api)))

(defun graphql-doc--get-api (name)
  "Get api plist NAME out of graphql-doc-apis."
  (cdr (assoc name graphql-doc-apis)))

(defun graphql-doc--get (key-list list)
  "Follow KEY-LIST to get property out of LIST."
  (if (and key-list list)
      (graphql-doc--get (cdr key-list) (assq (car key-list) list))
    (cdr list)))

(defun graphql-doc--get-types ()
  "Get info about types supported by endpoint."
  (graphql-doc--get '(data __schema types) graphql-doc--introspection-results))

(defun graphql-doc--get-type (name)
  "Get info about type NAME."
  (seq-find
   (lambda (type) (equal name (graphql-doc--get '(name) type)))
   (graphql-doc--get-types)))

(defun graphql-doc--queries ()
  "Get info about queries supported by endpoint."
  (seq-find
   (lambda (type) (equal (graphql-doc--get '(name) type) "Query"))
   (graphql-doc--get-types)))

(defun graphql-doc--mutations ()
  "Get info about mutations supported by endpoint."
  (seq-find
   (lambda (type) (equal (graphql-doc--get '(name) type) "Mutation"))
   (graphql-doc--get-types)))

(defvar-local graphql-doc--history nil
  "List of cons cells with a name and callback that can redraw each entry.")

(defun graphql-doc--history-push (name callback)
  "Add history entry with NAME and CALLBACK."
  (setq-local graphql-doc--history (cons `(,name . ,callback) graphql-doc--history)))

(defun graphql-doc-go-back ()
  "Go back to previous history entry."
  (interactive)
  (when (> (length graphql-doc--history) 1)
    (setq-local graphql-doc--history (cdr graphql-doc--history))
    (funcall (cdr (car graphql-doc--history)))))

(defun graphql-doc--draw-view (callback)
  "Draw view with CALLBACK."
  (setq inhibit-read-only t)
  (erase-buffer)
  (funcall callback)
  (setq inhibit-read-only nil)
  (goto-char (point-min)))

(defun graphql-doc--view (name callback)
  "Draw view with NAME and CALLBACK and and to history."
  (graphql-doc--history-push name (lambda () (graphql-doc--draw-view callback)))
  (graphql-doc--draw-view callback))

(defun graphql-doc--draw-object-type-button (type)
  "Draw a button for TYPE."
  (let ((kind (graphql-doc--get '(kind) type))
        (of-type (graphql-doc--get '(ofType) type))
        (name (graphql-doc--get '(name) type)))
    (cond ((equal kind "LIST")
           (graphql-doc--draw-object-type-button of-type)
           (insert "[]"))
          ((equal kind "NON_NULL")
           (graphql-doc--draw-object-type-button of-type)
           (insert "!"))
          ;; (type ))
          (t (if type
                 (graphql-doc--draw-button
                  name
                  (lambda ()
                    (interactive)
                    (graphql-doc--draw-object-page
                     (graphql-doc--get-type name))))
               (insert name))))))
  
(defun graphql-doc--draw-object-arg-button (arg)
  "Draw a button for ARG."
  (insert (graphql-doc--get '(name) arg) ": ")
  (graphql-doc--draw-object-type-button (graphql-doc--get '(type) arg)))

(defun graphql-doc--draw-object-arg-buttons (args)
  "Draw a list of ARGS."
  (when (> (length args) 0)
    (insert "(")
    (seq-map-indexed
     (lambda (arg idx)
       (graphql-doc--draw-object-arg-button arg)
       (when (< idx (- (length args) 1))
         (insert ", ")))
     args)
    (insert ")")))

(defun graphql-doc--draw-object-name-buttons (item)
  "Draw buttons for ITEM name."
  (let ((name (graphql-doc--get '(name) item))
        (args (graphql-doc--get '(args) item))
        (type (graphql-doc--get '(type) item)))
    (graphql-doc--draw-button name (graphql-doc--get-callback item))
    (graphql-doc--draw-object-arg-buttons args)
    (when type
      (insert ": ")
      (graphql-doc--draw-object-type-button type))
    (insert "\n\n")))

(defun graphql-doc--draw-list-item (item)
  "Draw ITEM in a list."
  (graphql-doc--draw-object-name-buttons item)
  (graphql-doc--draw-object-description item))

(defun graphql-doc--draw-list-separator (title)
  "Draw list item with TITLE."
  (insert "-----" title "-----" "\n\n"))

(defun graphql-doc--draw-list (item list-key title)
  "Draw a list of graphql properties from ITEM using LIST-KEY to get the list, with TITLE."
  (let ((item-list (graphql-doc--get (list list-key) item)))
    (when item-list
      (graphql-doc--draw-list-separator title)
      (seq-map
       #'graphql-doc--draw-list-item
       item-list))))

(defun graphql-doc--draw-object-description (graphql-object)
  "Draw GRAPHQL-OBJECT description if present."
  (let ((description (graphql-doc--get '(description) graphql-object)))
    (when (> (length description) 0)
      (insert description "\n\n"))))

(defun graphql-doc--draw-object (graphql-object)
  "Draw page for GRAPHQL-OBJECT."
  (insert "Name: " (graphql-doc--get '(name) graphql-object) "\n\n")
  (graphql-doc--draw-object-description graphql-object))

(defun graphql-doc--draw-button (label next)
  "Base button with LABEL and call NEXT when pressed."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] next)
    (define-key map [?\r] next)
    (insert-text-button label 'keymap map)))

(defun graphql-doc--get-callback (graphql-object)
  "Create view callback for GRAPHQL-OBJECT."
  (lambda ()
     (interactive)
     (graphql-doc--draw-object-page graphql-object)))

(defun graphql-doc--draw-object-page (query-object)
  "Draw page for QUERY-OBJECT."
  (graphql-doc--view
   (graphql-doc--get '(name) query-object)
   (lambda ()
     (graphql-doc--draw-object query-object)
     (graphql-doc--draw-list query-object 'args "Arguments")
     (graphql-doc--draw-list query-object 'fields "Fields")
     (graphql-doc--draw-list query-object 'inputFields "Fields")
     (graphql-doc--draw-list query-object 'enumValues "Enum Values"))))
                          
(defun graphql-doc--draw-root-page (name items)
  "Draw root page NAME with ITEMS representing root operations."
  (graphql-doc--view
   name
   (lambda ()
     (seq-map
      (lambda (item)
        (let ((name (graphql-doc--get '(name) item))
              (next (graphql-doc--get '(next) item)))
          (graphql-doc--draw-button name next)
          (insert "\n\n")
          (graphql-doc--draw-object-description item)))
      items))))
     
(defvar graphql-doc-mode-map (make-sparse-keymap)
  "The keymap for graphql-doc-mode.")

;; Define a key in the keymap
(define-key graphql-doc-mode-map (kbd "C-j") 'forward-button)
(define-key graphql-doc-mode-map (kbd "C-k") 'backward-button)
(define-key graphql-doc-mode-map (kbd "<backspace>") 'graphql-doc-go-back)

(define-derived-mode graphql-doc-mode
  special-mode "GraphQL Doc"
  "Major mode for GraphQL Doc viewing.")

(defun graphql-doc-reset ()
  "Reset vars."
  (interactive)
  (setq-local graphql-doc--history nil)
  (setq-local graphql-doc--introspection-results nil))

(defun graphql-doc--display-buffer (base-name)
  "Display GraphQL Doc buffer named BASE-NAME."
  (switch-to-buffer-other-window (generate-new-buffer-name (concat "*graphql-doc " base-name "*"))))

(defun graphql-doc--display-loading ()
  "Display loading screen."
  (graphql-doc--draw-view (lambda () (insert "Loading..."))))

(defun graphql-doc--start (name)
  "Initialize GraphQL Doc buffer for api NAME."
  (let ((buf (graphql-doc--display-buffer name)))
    (with-current-buffer buf
      (setq-local graphql-doc--history nil)
      (graphql-doc-mode)
      (graphql-doc--display-loading)
      (promise-chain (graphql-doc--request-introspection (graphql-doc--get-api name))
        (then
         (lambda (_)
           (graphql-doc--draw-root-page
            "Root"
            '(((name . "queries")
               (description . "Available queries")
               (next . (lambda () (interactive)
                         (graphql-doc--draw-object-page
                          (graphql-doc--queries)))))
              ((name . "mutations")
               (description . "Available mutations")
               (next . (lambda () (interactive)
                         (graphql-doc--draw-object-page
                          (graphql-doc--mutations)))))))))
        (promise-catch (lambda (reason) (message "failed to load %s" reason)))))))

(defun graphql-doc ()
  "Open graphql doc buffer."
  (interactive)
  (graphql-doc--start (completing-read
                       "Choose API: "
                       graphql-doc-apis)))

(provide 'graphql-doc)

;;; graphql-doc.el ends here
