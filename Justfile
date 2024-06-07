start:
    @docker run --rm -p 8080:8080 -p 8081:8081 \
        -p 3000:3000 openfga/openfga run

create-test-store:
    curl http://localhost:8080/stores --json '{"name": "FGA Demo Store"}'

list-stores:
    curl http://localhost:8080/stores