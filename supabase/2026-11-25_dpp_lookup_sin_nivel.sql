-- Registro de compra: el nivel del DPP deja de viajar al navegador.
-- PENDIENTE DE APLICAR (requiere aprobación). Aplicar ANTES de publicar el index.html nuevo.

-- 1) Búsqueda puntual por CUIT: solo nombre y contacto comercial, SIN nivel.
create or replace function public.dpp_lookup(p_cuit text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('found', true,
                               'name', coalesce(nullif(name, ''), dpp),
                               'chs',  channel_sales)
       from dpp_partners
      where regexp_replace(coalesce(cuit, ''), '\D', '', 'g') = regexp_replace(coalesce(p_cuit, ''), '\D', '', 'g')
        and length(regexp_replace(coalesce(p_cuit, ''), '\D', '', 'g')) = 11
      limit 1),
    jsonb_build_object('found', false));
$$;
revoke all on function public.dpp_lookup(text) from public;
grant execute on function public.dpp_lookup(text) to anon, authenticated;

-- 2) pr_register: el nivel y el monto de la NC se calculan en el servidor
--    (se ignoran tier / nc_amount enviados por el navegador) y se devuelve nc_amount.
--    NC = 90% del precio de lista del NVR demo: DIAMOND 249.50 -> 224.55, BLACK 274.10 -> 246.69.
create or replace function public.pr_register(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  r purchase_registrations%rowtype;
  v_cuit text := regexp_replace(coalesce(p->>'cuit', ''), '\D', '', 'g');
  v_tier text;
  v_nc   numeric;
begin
  select upper(tier) into v_tier from dpp_partners
   where regexp_replace(coalesce(cuit, ''), '\D', '', 'g') = v_cuit limit 1;
  v_nc := case v_tier when 'DIAMOND' then 224.55 when 'BLACK' then 246.69 end;

  select * into r from purchase_registrations
    where cuit = p->>'cuit' and campaign = p->>'campaign' order by created_at limit 1 for update;
  if found then
    update purchase_registrations set
      lines         = coalesce(lines, '[]'::jsonb)         || coalesce(p->'lines', '[]'::jsonb),
      items         = coalesce(items, '[]'::jsonb)         || coalesce(p->'items', '[]'::jsonb),
      factura_files = coalesce(factura_files, '[]'::jsonb) || coalesce(p->'factura_files', '[]'::jsonb),
      rrss_files    = coalesce(rrss_files, '[]'::jsonb)    || coalesce(p->'rrss_files', '[]'::jsonb),
      rrss_link     = coalesce(rrss_link, nullif(p->>'rrss_link', '')),
      eligible      = coalesce(eligible, false) or coalesce((p->>'eligible')::boolean, false),
      nc_status     = case when nc_status is null and coalesce((p->>'eligible')::boolean, false) then 'pending_review' else nc_status end,
      nd            = (select string_agg(distinct x, ', ') from unnest(string_to_array(coalesce(nd, '') || ', ' || coalesce(p->>'nd', ''), ', ')) x where x <> ''),
      comentarios   = concat_ws(E'\n', comentarios, 'Ampliado ' || to_char(now(), 'DD/MM/YYYY') || ' (nuevo envío del mismo DPP)')
      where id = r.id;
    return jsonb_build_object('merged', true, 'folio', r.folio, 'fecha', to_char(r.created_at, 'DD/MM/YYYY'));
  end if;
  insert into purchase_registrations (campaign, campaign_name, cuit, dpp, contacto, tier, nc_amount, eligible, folio, nc_status, nd,
      lines, items, factura_files, rrss_files, rrss_link, factura_fecha, demo_model, demo_nd, nc_nd, source)
    values (p->>'campaign', p->>'campaign_name', p->>'cuit', p->>'dpp', p->>'contacto', v_tier,
      v_nc, coalesce((p->>'eligible')::boolean, false), p->>'folio', p->>'nc_status', p->>'nd',
      coalesce(p->'lines', '[]'::jsonb), coalesce(p->'items', '[]'::jsonb), coalesce(p->'factura_files', '[]'::jsonb),
      coalesce(p->'rrss_files', '[]'::jsonb), nullif(p->>'rrss_link', ''), nullif(p->>'factura_fecha', '')::date,
      p->>'demo_model', p->>'demo_nd', p->>'nc_nd', coalesce(p->>'source', 'public'));
  return jsonb_build_object('merged', false, 'folio', p->>'folio',
                            'nc_amount', case when coalesce((p->>'eligible')::boolean, false) then v_nc end);
end $function$;
