--
-- Schema up
--

--
-- Define enum types
create type battle_t as enum ('slot','height');

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
-- Slot and height battles with opponent(s) and battle result.
create table battle (
    id bigserial primary key,
    block_id bigint unique references block(id) on delete cascade on update cascade,
    type battle_t not null,
    against varchar(32) not null,
    is_won boolean not null,
    created_at timestamp not null default now()
);

--
-- A timestamp from every node of when the chain was extended.
create table propagation (
    id bigserial primary key,
    block_id bigint references block(id) on delete cascade on update cascade,
    hostname varchar(32) not null,
    extended_at timestamp,
    created_at timestamp not null default now(),
    unique (block_id, hostname)
);

--
-- Storing the leaderlog allows missed slots to be reported.
create table leaderlog (
    id bigserial primary key,
    epoch smallint not null,
    nr smallint not null,
    slot bigint unique default null,
    scheduled_at timestamp with time zone default null,
    created_at timestamp not null default now()
);
