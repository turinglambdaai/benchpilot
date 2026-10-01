#lang racket/base

;; ICanBus.cs port: one CAN frame as the ISO-TP layer needs it, and the bus
;; contract every transport (SocketCAN, PCAN, in-process simulated) satisfies.
;; The diagnostic layer never talks to vendor SDKs directly.

(require racket/contract
         racket/generic)

(require benchpilot/diagnostics/isotp/codec)

(provide gen:can-bus
         can-bus?
         can-bus-name
         can-bus-open!
         can-bus-send!
         can-bus-on-frame!
         can-bus-dispose!)

;; Frames on the bus are the codec's (can-frame id extended? data) records;
;; data is a list of at most 8 bytes for classic CAN.
(define-generics can-bus
  (can-bus-name can-bus)
  (can-bus-open! can-bus)
  (can-bus-send! can-bus frame)
  (can-bus-on-frame! can-bus listener)
  (can-bus-dispose! can-bus))
