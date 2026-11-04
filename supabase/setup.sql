-- BULLET 세계 랭킹: Supabase SQL Editor에 이 파일 전체를 붙여 넣고 Run 하세요.
-- 여러 번 실행해도 안전하고, 이전 버전으로 만든 테이블과 기록은 그대로 유지됩니다.

create table if not exists public.scores (
  id         bigint generated always as identity primary key,
  name       text        not null check (char_length(name) between 1 and 16),
  country    text        not null default 'UN' check (country ~ '^[A-Z]{2}$'),
  score      integer     not null check (score >= 0),
  stage      integer     not null check (stage between 1 and 500),
  created_at timestamptz not null default now()
);

-- 데일리 챌린지: mode = 'daily'이면 day(UTC 날짜)가 반드시 있어야 합니다.
alter table public.scores add column if not exists mode text not null default 'normal';
alter table public.scores add column if not exists day  date;
alter table public.scores drop constraint if exists scores_mode_check;
alter table public.scores add constraint scores_mode_check
  check (mode in ('normal', 'daily') and ((mode = 'daily') = (day is not null)));

create index if not exists scores_score_idx   on public.scores (score desc, created_at);
create index if not exists scores_created_idx on public.scores (created_at desc);
create index if not exists scores_board_idx   on public.scores (mode, day, score desc);

-- 누구나 읽을 수 있고, 테이블에 직접 쓰는 것은 막습니다.
alter table public.scores enable row level security;
drop policy if exists "scores are public" on public.scores;
create policy "scores are public" on public.scores for select to anon, authenticated using (true);
grant select on public.scores to anon, authenticated;
revoke insert, update, delete on public.scores from anon, authenticated;

-- 이전 버전의 등록 함수(인자 4개)는 지웁니다.
drop function if exists public.submit_score(text, text, int, int);

-- 기록 등록은 이 함수로만 가능합니다. 이름/국가 정리, 점수 상한 검사, 연속 등록 제한을 합니다.
create or replace function public.submit_score(
  p_name text, p_country text, p_score int, p_stage int,
  p_mode text default 'normal', p_day date default null)
returns table (out_id bigint, out_rank bigint, out_total bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name    text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_country text := upper(coalesce(p_country, 'UN'));
  v_mode    text := coalesce(p_mode, 'normal');
  v_today   date := (now() at time zone 'utc')::date;
  v_day     date := null;
  v_max     bigint;
  v_id      bigint;
begin
  if char_length(v_name) < 1 or char_length(v_name) > 16 then
    raise exception 'invalid name';
  end if;
  if v_country !~ '^[A-Z]{2}$' then
    v_country := 'UN';
  end if;
  if v_mode not in ('normal', 'daily') then
    raise exception 'invalid mode';
  end if;
  if v_mode = 'daily' then
    -- 시간대 차이를 고려해 어제~내일(UTC)까지만 받습니다.
    if p_day is null or p_day < v_today - 1 or p_day > v_today + 1 then
      raise exception 'invalid day';
    end if;
    v_day := p_day;
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

  insert into scores (name, country, score, stage, mode, day)
  values (v_name, v_country, p_score, p_stage, v_mode, v_day)
  returning scores.id into v_id;

  -- 같은 랭킹(일반 또는 그날의 데일리) 안에서, 플레이어별 최고 기록 기준 순위
  return query
    with b as (
      select s.name, s.country, max(s.score) as m
      from scores s
      where s.mode = v_mode and s.day is not distinct from v_day
      group by s.name, s.country
    )
    select v_id,
           (select count(*) from b where b.m > p_score) + 1,
           (select count(*) from b);
end;
$$;

revoke all on function public.submit_score(text, text, int, int, text, date) from public;
grant execute on function public.submit_score(text, text, int, int, text, date) to anon, authenticated;

-- 랭킹 목록: 플레이어(닉네임+국가)마다 최고 기록 한 줄씩
create or replace function public.top_scores(
  p_mode text default 'normal', p_day date default null,
  p_since timestamptz default null, p_limit int default 50)
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
    where s.mode = coalesce(p_mode, 'normal')
      and s.day is not distinct from (case when coalesce(p_mode, 'normal') = 'daily' then p_day end)
      and (p_since is null or s.created_at >= p_since)
    order by s.name, s.country, s.score desc, s.created_at asc
  ) b
  order by b.score desc, b.created_at asc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

revoke all on function public.top_scores(text, date, timestamptz, int) from public;
grant execute on function public.top_scores(text, date, timestamptz, int) to anon, authenticated;

-- 국가 대항전: 국가 점수 = 그 나라 상위 10명(플레이어별 최고 기록)의 합계. '기타(UN)'는 제외.
create or replace function public.country_stats(
  p_mode text default 'normal', p_day date default null, p_since timestamptz default null)
returns table (country text, players bigint, points bigint, top_name text, top_score int)
language sql
stable
security definer
set search_path = public
as $$
  with best as (
    select distinct on (s.name, s.country) s.name, s.country, s.score
    from scores s
    where s.mode = coalesce(p_mode, 'normal')
      and s.day is not distinct from (case when coalesce(p_mode, 'normal') = 'daily' then p_day end)
      and (p_since is null or s.created_at >= p_since)
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

revoke all on function public.country_stats(text, date, timestamptz) from public;
grant execute on function public.country_stats(text, date, timestamptz) to anon, authenticated;
