# Pinned by digest; Dependabot (docker ecosystem) keeps the tag and digest current.
FROM busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec

ARG GREETING
LABEL greeting="${GREETING}"

# Fails unless build_secrets passes fixture_secret (compared by its SHA-256, so
# that the value itself appears nowhere in the image). The secret is mounted for
# this step only and ends up neither in a layer nor in the image history.
RUN --mount=type=secret,id=fixture_secret,required=true \
    test "$(sha256sum < /run/secrets/fixture_secret | cut -c1-64)" = \
    "0248f56577e62962fd6ae2f4d93b4ae9323f4976469d53ffa6953d3bd0f1664d"

COPY Dockerfile /Dockerfile
