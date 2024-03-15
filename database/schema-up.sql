--
-- Schema up
--

--
-- Define enum types
create type battle_t as enum ('slot','height');

--
-- Table describing all nodes in this pool.
create table relay (
    id serial primary key,
    hostname varchar(32) not null,
    created_at timestamp not null default now()
);

--
-- Table for blocks produced by the core node.
create table block (
    id bigserial primary key,
    slot bigint unique not null,
    epoch smallint not null,
    height bigint not null,
    hash varchar(64) not null,
    forged_at timestamp,
    adopted_at timestamp,
    pooltool_ms decimal(6,2),
    created_at timestamp not null default now()
);

--
-- Slot and height battles with opponent and battle result.
create table battle (
    id bigserial primary key,
    block_id bigint unique references block(id) on delete cascade on update cascade,
    type battle_t not null,
    against varchar(64) not null,
    is_won boolean not null,
    created_at timestamp not null default now()
);

--
-- A timestamp from every node of when the chain was extended.
create table propagation (
    id bigserial primary key,
    relay_id integer references relay(id) on delete set null on update cascade,
    block_id bigint references block(id) on delete cascade on update cascade,
    extended_at timestamp,
    created_at timestamp not null default now(),
    unique (relay_id, block_id)
);

--
-- Storing the leaderlog allows for reporting of missed blocks.
create table leaderlog (
    id bigserial primary key,
    nr smallint not null,
    slot bigint not null,
    epoch smallint not null,
    created_at timestamp not null default now()
);