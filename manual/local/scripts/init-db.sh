#!/bin/bash
# =============================================================================
# OpenTraum — PostgreSQL Initialization Script
# =============================================================================
# This script is executed automatically by PostgreSQL on first startup.
# It creates separate databases for each microservice following the
# database-per-service pattern in MSA.
# =============================================================================

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL

    -- Auth Service Database
    CREATE DATABASE opentraum_auth
        OWNER = opentraum
        ENCODING = 'UTF8'
        LC_COLLATE = 'en_US.utf8'
        LC_CTYPE = 'en_US.utf8';

    -- User Service Database
    CREATE DATABASE opentraum_user
        OWNER = opentraum
        ENCODING = 'UTF8'
        LC_COLLATE = 'en_US.utf8'
        LC_CTYPE = 'en_US.utf8';

    -- Event Service Database
    CREATE DATABASE opentraum_event
        OWNER = opentraum
        ENCODING = 'UTF8'
        LC_COLLATE = 'en_US.utf8'
        LC_CTYPE = 'en_US.utf8';

    -- Reservation Service Database
    CREATE DATABASE opentraum_reservation
        OWNER = opentraum
        ENCODING = 'UTF8'
        LC_COLLATE = 'en_US.utf8'
        LC_CTYPE = 'en_US.utf8';

    -- Payment Service Database
    CREATE DATABASE opentraum_payment
        OWNER = opentraum
        ENCODING = 'UTF8'
        LC_COLLATE = 'en_US.utf8'
        LC_CTYPE = 'en_US.utf8';

    -- Grant all privileges
    GRANT ALL PRIVILEGES ON DATABASE opentraum_auth TO opentraum;
    GRANT ALL PRIVILEGES ON DATABASE opentraum_user TO opentraum;
    GRANT ALL PRIVILEGES ON DATABASE opentraum_event TO opentraum;
    GRANT ALL PRIVILEGES ON DATABASE opentraum_reservation TO opentraum;
    GRANT ALL PRIVILEGES ON DATABASE opentraum_payment TO opentraum;

EOSQL
