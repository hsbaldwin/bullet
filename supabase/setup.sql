-- BULLET 세계 랭킹: Supabase SQL Editor에 이 파일 전체를 붙여 넣고 Run 하세요.
-- 여러 번 실행해도 안전합니다. 이전 버전으로 만든 테이블의 일반 기록은 그대로 유지됩니다.

create table if not exists public.scores (
  id         bigint generated always as identity primary key,
  name       text        not null check (char_length(name) between 1 and 16),
  country    text        not null default 'UN' check (country ~ '^[A-Z]{2}$'),
  score      integer     not null check (score >= 0),
  stage      integer     not null check (stage between 1 and 500),
  created_at timestamptz not null default now()
);

-- 정리: 없어진 데일리 기능의 흔적(데일리 기록, mode/day 칸, 함수 인자)을 지웁니다.
-- 데일리를 한 번도 쓰지 않았다면 아무것도 바뀌지 않습니다.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'scores' and column_name = 'mode') then
    delete from public.scores where mode = 'daily';
  end if;
end $$;
alter table public.scores drop constraint if exists scores_mode_check;
drop index if exists public.scores_board_idx;
alter table public.scores drop column if exists day;
alter table public.scores drop column if exists mode;
drop function if exists public.submit_score(text, text, int, int, text, date);
drop function if exists public.top_scores(text, date, timestamptz, int);
drop function if exists public.country_stats(text, date, timestamptz);

create index if not exists scores_score_idx   on public.scores (score desc, created_at);
create index if not exists scores_created_idx on public.scores (created_at desc);

-- 누구나 읽을 수 있고, 테이블에 직접 쓰는 것은 막습니다.
alter table public.scores enable row level security;
drop policy if exists "scores are public" on public.scores;
create policy "scores are public" on public.scores for select to anon, authenticated using (true);
grant select on public.scores to anon, authenticated;
revoke insert, update, delete on public.scores from anon, authenticated;

-- 기록 등록은 이 함수로만 가능합니다. 이름/국가 정리, 점수 상한 검사, 연속 등록 제한을 합니다.
create or replace function public.submit_score(p_name text, p_country text, p_score int, p_stage int)
returns table (out_id bigint, out_rank bigint, out_total bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name    text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_country text := upper(coalesce(p_country, 'UN'));
  v_max     bigint;
  v_id      bigint;
begin
  if char_length(v_name) < 1 or char_length(v_name) > 16 then
    raise exception 'invalid name';
  end if;
  if v_country !~ '^[A-Z]{2}$' then
    v_country := 'UN';
  end if;
  if p_stage is null or p_stage < 1 or p_stage > 500 then
    raise exception 'invalid stage';
  end if;
  -- 스테이지 n에서 게임 오버 = n-1개 클리어. 한 스테이지 최대 398점 + 연속 원샷 보너스가 25점씩 증가.
  v_max := (p_stage - 1) * 400 + 25 * (p_stage - 1) * greatest(p_stage - 2, 0) / 2;
  if p_score is null or p_score < 1 or p_score > v_max then
    raise exception 'implausible score';
  end if;
  if exists (select 1 from scores s where s.name = v_name and s.created_at > now() - interval '20 seconds') then
    raise exception 'too many submissions';
  end if;

  insert into scores (name, country, score, stage)
  values (v_name, v_country, p_score, p_stage)
  returning scores.id into v_id;

  -- 플레이어(닉네임+국가)별 최고 기록 기준 순위
  return query
    with b as (
      select s.name, s.country, max(s.score) as m
      from scores s
      group by s.name, s.country
    )
    select v_id,
           (select count(*) from b where b.m > p_score) + 1,
           (select count(*) from b);
end;
$$;

revoke all on function public.submit_score(text, text, int, int) from public;
grant execute on function public.submit_score(text, text, int, int) to anon, authenticated;

-- 랭킹 목록: 플레이어(닉네임+국가)마다 최고 기록 한 줄씩. p_since를 주면 그 이후 기록만.
create or replace function public.top_scores(p_since timestamptz default null, p_limit int default 50)
returns table (name text, country text, score int, stage int, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select b.name, b.country, b.score, b.stage, b.created_at
  from (
    select distinct on (s.name, s.country) s.name, s.country, s.score, s.stage, s.created_at
    from scores s
    where p_since is null or s.created_at >= p_since
    order by s.name, s.country, s.score desc, s.created_at asc
  ) b
  order by b.score desc, b.created_at asc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

revoke all on function public.top_scores(timestamptz, int) from public;
grant execute on function public.top_scores(timestamptz, int) to anon, authenticated;

-- 국가 대항전: 국가 점수 = 그 나라 상위 10명(플레이어별 최고 기록)의 합계. '기타(UN)'는 제외.
create or replace function public.country_stats(p_since timestamptz default null)
returns table (country text, players bigint, points bigint, top_name text, top_score int)
language sql
stable
security definer
set search_path = public
as $$
  with best as (
    select distinct on (s.name, s.country) s.name, s.country, s.score
    from scores s
    where (p_since is null or s.created_at >= p_since)
      and s.country <> 'UN'
    order by s.name, s.country, s.score desc, s.created_at asc
  ), ranked as (
    select b.name, b.country, b.score,
           row_number() over (partition by b.country order by b.score desc, b.name) as rn
    from best b
  )
  select r.country,
         count(*)::bigint,
         coalesce(sum(r.score) filter (where r.rn <= 10), 0)::bigint,
         max(r.name) filter (where r.rn = 1),
         max(r.score) filter (where r.rn = 1)
  from ranked r
  group by r.country
  order by 3 desc, 2 desc
  limit 100;
$$;

revoke all on function public.country_stats(timestamptz) from public;
grant execute on function public.country_stats(timestamptz) to anon, authenticated;
