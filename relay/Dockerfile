FROM racket/racket:9.3

WORKDIR /app
COPY racket/ ./racket/

# Set your shared token at deploy time.
ENV MOONBEAM_RELAY_TOKEN=change-me
EXPOSE 8090

CMD ["racket", "racket/moonbeam/relay.rkt", "--port", "8090"]
