-- BULLET 세계 랭킹: Supabase SQL Editor에 이 파일 전체를 붙여 넣고 Run 하세요. 여러 번 실행해도 안전합니다.
--
-- 규칙
--   * 랭킹은 플레이어당 한 줄. 같은 플레이어가 다시 올리면 더 높은 점수일 때만 갱신됩니다.
--   * 플레이어는 브라우저가 만든 비밀 토큰으로 구별합니다. 서버에는 토큰의 SHA-256 해시만 저장합니다.
--   * 닉네임은 대소문자 구분 없이 한 사람만 쓸 수 있습니다.
--   * 국가는 접속 IP로 서버가 정합니다(Cloudflare의 cf-ipcountry 헤더). 게임이 보낸 값은 쓰지 않습니다.
--   * 같은 IP에서는 하루에 새 플레이어를 3명까지만 만들 수 있습니다. IP는 비밀 salt를 섞은 해시로만 저장합니다.

-- ── 이전 버전 정리 ──
-- 이전 버전의 함수는 지웁니다. 이전 버전의 기록 테이블(public.scores)은 지우지 않고 그대로 둡니다.
-- 필요 없다면 직접 다음을 실행하세요:  drop table if exists public.scores;
drop function if exists public.submit_score(text, text, int, int);
drop function if exists public.submit_score(text, text, int, int, text, date);
drop function if exists public.top_scores(timestamptz, int);
drop function if exists public.top_scores(text, date, timestamptz, int);
drop function if exists public.country_stats(timestamptz);
drop function if exists public.country_stats(text, date, timestamptz);

-- ── 비밀 salt (IP 해시용, 누구도 API로 읽을 수 없음) ──
create table if not exists public.bullet_secret (
  id   int  primary key default 1 check (id = 1),
  salt text not null
);
alter table public.bullet_secret enable row level security;
revoke all on public.bullet_secret from anon, authenticated;
insert into public.bullet_secret (id, salt)
values (1, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (id) do nothing;

-- ── 플레이어 테이블 (API로 직접 읽거나 쓸 수 없음, 아래 함수로만 접근) ──
create table if not exists public.players (
  id             bigint generated always as identity primary key,
  name           text        not null check (char_length(name) between 1 and 16),
  name_key       text        not null unique,
  token_hash     text        not null unique,
  ip_hash        text,
  country        text        not null default 'UN' check (country ~ '^[A-Z]{2}$'),
  score          integer     not null check (score >= 0),
  stage          integer     not null check (stage between 1 and 500),
  best_at        timestamptz not null default now(),
  last_submit_at timestamptz not null default now(),
  created_at     timestamptz not null default now()
);
create index if not exists players_rank_idx on public.players (score desc, best_at);
create index if not exists players_ip_idx   on public.players (ip_hash, created_at);
alter table public.players enable row level security;
revoke all on public.players from anon, authenticated;

-- ── 내부 도우미 (API에서 호출 불가) ──
create or replace function public.bullet_header(p_name text)
returns text
language sql
stable
as $$
  select nullif(btrim(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json ->> p_name), '')
$$;

create or replace function public.bullet_country()
returns text
language plpgsql
stable
set search_path = public
as $$
declare
  c text := upper(coalesce(bullet_header('cf-ipcountry'), bullet_header('x-country-code'),
                           bullet_header('cloudfront-viewer-country'), bullet_header('x-vercel-ip-country'), ''));
begin
  -- XX: 알 수 없음, T1: Tor (Cloudflare 표기)
  if c ~ '^[A-Z]{2}$' and c not in ('XX', 'T1') then
    return c;
  end if;
  return 'UN';
end;
$$;

create or replace function public.bullet_ip_hash()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ip text := coalesce(bullet_header('cf-connecting-ip'),
                      nullif(btrim(split_part(coalesce(bullet_header('x-forwarded-for'), ''), ',', 1)), ''),
                      bullet_header('x-real-ip'));
begin
  if ip is null then
    return null;
  end if;
  return encode(sha256(convert_to((select salt from bullet_secret where id = 1) || '|' || ip, 'UTF8')), 'hex');
end;
$$;

create or replace function public.bullet_token_hash(p_token text)
returns text
language sql
immutable
as $$
  select encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
$$;

-- 순위: 점수가 높을수록, 같은 점수면 먼저 달성한 사람이 위
create or replace function public.bullet_rank(p_score int, p_best_at timestamptz)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*) + 1 from players x
  where x.score > p_score or (x.score = p_score and x.best_at < p_best_at)
$$;

revoke all on function public.bullet_header(text)               from public, anon, authenticated;
revoke all on function public.bullet_country()                  from public, anon, authenticated;
revoke all on function public.bullet_ip_hash()                  from public, anon, authenticated;
revoke all on function public.bullet_token_hash(text)           from public, anon, authenticated;
revoke all on function public.bullet_rank(int, timestamptz)     from public, anon, authenticated;

-- ── 기록 등록 ──
create or replace function public.submit_score(p_token text, p_name text, p_score int, p_stage int)
returns table (out_rank bigint, out_total bigint, out_best int, out_improved boolean, out_country text, out_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name     text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_key      text;
  v_hash     text;
  v_country  text := bullet_country();
  v_ip       text := bullet_ip_hash();
  v_max      bigint;
  v_improved boolean := false;
  p          players%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid token';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 16 then
    raise exception 'invalid name';
  end if;
  v_key := lower(v_name);
  if p_stage is null or p_stage < 1 or p_stage > 500 then
    raise exception 'invalid stage';
  end if;
  -- 스테이지 n에서 게임 오버 = n-1개 클리어. 한 스테이지 최대 398점 + 연속 원샷 보너스가 25점씩 증가.
  v_max := (p_stage - 1) * 400 + 25 * (p_stage - 1) * greatest(p_stage - 2, 0) / 2;
  if p_score is null or p_score < 1 or p_score > v_max then
    raise exception 'implausible score';
  end if;
  v_hash := bullet_token_hash(p_token);

  select * into p from players where token_hash = v_hash for update;
  if found then
    if p.last_submit_at > now() - interval '10 seconds' then
      raise exception 'too many submissions';
    end if;
    if p.name_key <> v_key and exists (select 1 from players x where x.name_key = v_key) then
      raise exception 'name taken';
    end if;
    v_improved := p_score > p.score;
    update players set
      name           = v_name,
      name_key       = v_key,
      score          = case when v_improved then p_score   else score   end,
      stage          = case when v_improved then p_stage   else stage   end,
      best_at        = case when v_improved then now()     else best_at end,
      country        = case when v_improved then v_country else country end,
      last_submit_at = now()
    where id = p.id;
  else
    if exists (select 1 from players x where x.name_key = v_key) then
      raise exception 'name taken';
    end if;
    if v_ip is not null and
       (select count(*) from players x where x.ip_hash = v_ip and x.created_at > now() - interval '1 day') >= 3 then
      raise exception 'too many players from this network';
    end if;
    begin
      insert into players (name, name_key, token_hash, ip_hash, country, score, stage)
      values (v_name, v_key, v_hash, v_ip, v_country, p_score, p_stage);
    exception when unique_violation then
      raise exception 'name taken';
    end;
    v_improved := true;
  end if;

  return query
    select bullet_rank(pl.score, pl.best_at), (select count(*) from players), pl.score, v_improved, pl.country, pl.name
    from players pl where pl.token_hash = v_hash;
end;
$$;

-- ── 내 정보: 접속 국가와(등록돼 있다면) 내 기록 ──
create or replace function public.my_entry(p_token text default null)
returns table (country text, name text, score int, stage int, rank bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_country text := bullet_country();
begin
  return query
    select v_country, pl.name, pl.score, pl.stage,
           case when pl.id is null then null else bullet_rank(pl.score, pl.best_at) end
    from (select 1) d
    left join players pl on p_token is not null and pl.token_hash = bullet_token_hash(p_token);
end;
$$;

-- ── 랭킹 목록 (플레이어당 한 줄) ──
create or replace function public.top_scores(p_limit int default 50)
returns table (name text, country text, score int, stage int)
language sql
stable
security definer
set search_path = public
as $$
  select pl.name, pl.country, pl.score, pl.stage
  from players pl
  order by pl.score desc, pl.best_at asc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

revoke all on function public.submit_score(text, text, int, int) from public;
revoke all on function public.my_entry(text)                     from public;
revoke all on function public.top_scores(int)                    from public;
grant execute on function public.submit_score(text, text, int, int) to anon, authenticated;
grant execute on function public.my_entry(text)                     to anon, authenticated;
grant execute on function public.top_scores(int)                    to anon, authenticated;

-- API가 새 함수를 바로 알아보도록 스키마 캐시를 새로 고칩니다.
notify pgrst, 'reload schema';
