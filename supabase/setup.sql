-- BULLET 세계 랭킹: Supabase SQL Editor에 이 파일 전체를 붙여 넣고 Run 하세요.
-- 여러 번 실행해도 안전합니다.

create table if not exists public.scores (
  id         bigint generated always as identity primary key,
  name       text        not null check (char_length(name) between 1 and 16),
  country    text        not null default 'UN' check (country ~ '^[A-Z]{2}$'),
  score      integer     not null check (score >= 0),
  stage      integer     not null check (stage between 1 and 500),
  created_at timestamptz not null default now()
);
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

  return query
    select v_id,
           (select count(*) from scores s where s.score > p_score) + 1,
           (select count(*) from scores);
end;
$$;

revoke all on function public.submit_score(text, text, int, int) from public;
grant execute on function public.submit_score(text, text, int, int) to anon, authenticated;
