# PostgreSQL Database TODOs

## 1. Sync PostgreSQL Secrets ⏳
**Status**: Pending  
**Description**: Sync PostgreSQL secrets to todoable and pennematz applications

**Details**:
- Todoable already has `envFrom` with the secret
- Pennematz has `DB_URL` from secret  
- May need Reflector to sync secrets across namespaces
- Verify cross-namespace secret access

**Implementation**: 
- Check Reflector configuration
- Ensure secrets are synced to `app-todoable` and `app-pennematz` namespaces

## 2. Create User Schemas ⏳
**Status**: Pending  
**Description**: Create dedicated schemas for each user when creating database and user, ensuring proper table creation rights

**Details**:
- Each user should get their own schema (e.g., `todoable_app`, `pennematz_app`)
- Schema should be owned by the respective user
- Ensures clean separation and proper permissions

**Implementation Options**:
- Add init scripts to PostgresCluster
- Use custom SQL initialization  
- Create schemas post-deployment via Jobs
- Update PostgresCluster with custom initialization

**Current Users**:
- `pg-todoable-user` → database: `pg-todoable-db`
- `pg-pennematz-user` → database: `pg-pennematz-db`

**Target Schemas**:
- `todoable_app` schema for todoable application
- `pennematz_app` schema for pennematz application
