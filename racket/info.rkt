#lang info

(define collection 'multi)
(define pkg-desc "Moonbeam: self-hosted remote access for the agent era (text lane)")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)

(define deps
  '(["base" #:version "9.0"]))

(define build-deps
  '("rackunit-lib"))
