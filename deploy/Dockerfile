# Production n8n image: the official image plus trust in Supabase's private CA, so every
# PostgreSQL connection (n8n state and workflow credentials) verifies certificates.
# Build context: repository root.
FROM n8nio/n8n:2.43.7

# Public CA certificate (not a secret), downloaded from the Supabase dashboard.
COPY deploy/supabase-ca.crt /etc/ssl/certs/supabase-ca.crt
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/supabase-ca.crt
