// kehi-pay-test — Cardcom PUBLIC demo terminal only. NOT a live merchant terminal.
// Documented test values (https://kb.cardcom.solutions/apijosn/en/articles/503/create-payment-page-retrieve-transaction-details
// and https://support.cardcom.solutions/hc/he/articles/360002688814):
//   TerminalNumber = 1000, ApiName = cardtest26
// No service_role key. Webhook authenticates with PAY_WEBHOOK_SECRET (hash stored in private.pay_webhook_config).
// Test mode: no invoice emails.

const CARDCOM_CREATE = 'https://secure.cardcom.solutions/api/v11/LowProfile/Create';
const CARDCOM_RESULT = 'https://secure.cardcom.solutions/api/v11/LowProfile/GetLpResult';

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'authorization, content-type, apikey',
      'access-control-allow-methods': 'POST, GET, OPTIONS'
    }
  });
}

export default {
  async fetch(req, env) {
    if (req.method === 'OPTIONS') return json({ ok: true });
    const url = new URL(req.url);
    if (req.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, mode: 'test', payments_configured: !!(env.CARDCOM_TERMINAL && env.CARDCOM_API_NAME) });
    }
    if (req.method === 'POST' && url.pathname === '/pay/create') return createPayment(req, env);
    if (req.method === 'POST' && url.pathname === '/pay/webhook') return handleWebhook(req, env);
    return json({ error: 'not found' }, 404);
  }
};

async function staffFromJwt(req, env) {
  const auth = req.headers.get('authorization') || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token || !env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) return null;
  const u = await fetch(env.SUPABASE_URL + '/auth/v1/user', {
    headers: { apikey: env.SUPABASE_ANON_KEY, authorization: 'Bearer ' + token }
  });
  if (!u.ok) return null;
  const user = await u.json();
  const who = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/admin_whoami', {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      authorization: 'Bearer ' + token,
      'content-type': 'application/json'
    },
    body: '{}'
  });
  if (!who.ok) return null;
  const w = await who.json();
  if (!(w && (w.is_admin || w.is_manager))) return null;
  return { user, role: w.role, token };
}

async function createPayment(req, env) {
  const staff = await staffFromJwt(req, env);
  if (!staff) return json({ error: 'staff_only', message: 'רק צוות יכול לבדוק תשלום במצב בדיקה' }, 401);
  let body;
  try { body = await req.json(); } catch { return json({ error: 'bad_json' }, 400); }
  const tierId = String(body.tier_id || '');
  const cycle = String(body.billing_cycle || '');
  const amount = Number(body.amount_ils);
  const productName = String(body.product_name || 'מסלול בדיקה');
  if (!tierId || !(amount > 0) || (cycle !== 'monthly' && cycle !== 'yearly')) {
    return json({ error: 'bad_request' }, 400);
  }
  if (!env.CARDCOM_TERMINAL || !env.CARDCOM_API_NAME) {
    return json({ error: 'payments_not_configured' }, 503);
  }
  const origin = env.PAYMENT_SUCCESS_URL || 'https://nahat-app.ranbenri.workers.dev/#/me';
  const fail = env.PAYMENT_FAILED_URL || 'https://nahat-app.ranbenri.workers.dev/#/pricing';
  const hook = env.CARDCOM_WEBHOOK_PUBLIC_URL || (new URL(req.url)).origin + '/pay/webhook';
  const payload = {
    TerminalNumber: Number(env.CARDCOM_TERMINAL),
    ApiName: env.CARDCOM_API_NAME,
    Operation: cycle === 'yearly' ? 'ChargeOnly' : 'ChargeAndCreateToken',
    Amount: Math.round(amount * 100) / 100,
    ReturnValue: `${staff.user.id}:${tierId}:${cycle}:test`.slice(0, 250),
    SuccessRedirectUrl: origin,
    FailedRedirectUrl: fail,
    WebHookUrl: hook,
    Language: 'he',
    ISOCoinId: 1,
    ProductName: ('בדיקה — ' + productName).slice(0, 50)
    // No Document / no emails in test.
  };
  const res = await fetch(CARDCOM_CREATE, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload)
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.ResponseCode !== 0 || !data.Url) {
    return json({ error: 'cardcom_create_failed', response_code: data.ResponseCode, description: data.Description }, 502);
  }
  return json({ url: data.Url, lowprofile_id: data.LowProfileId, mode: 'test' });
}

async function handleWebhook(req, env) {
  let body;
  try { body = await req.json(); } catch {
    const text = await req.text();
    try { body = Object.fromEntries(new URLSearchParams(text)); } catch { body = {}; }
  }
  const lowProfileId = body.LowProfileId || body.lowprofileid || body.lowProfileId;
  if (!lowProfileId) return json({ error: 'missing_lowprofile_id' }, 400);
  if (!env.CARDCOM_TERMINAL || !env.CARDCOM_API_NAME) return json({ error: 'payments_not_configured' }, 503);

  const verify = await fetch(CARDCOM_RESULT, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      TerminalNumber: Number(env.CARDCOM_TERMINAL),
      ApiName: env.CARDCOM_API_NAME,
      LowProfileId: lowProfileId
    })
  });
  const result = await verify.json().catch(() => ({}));
  if (result.ResponseCode !== 0) {
    return json({ ok: false, response_code: result.ResponseCode, description: result.Description });
  }
  const ret = String(result.ReturnValue || '');
  const [userId, tierId, cycle] = ret.split(':');
  const amount = Number(result.Amount || (result.TranzactionInfo && result.TranzactionInfo.Amount) || 0);
  const tranzactionId = String(result.TranzactionId || result.TransactionId || '');
  const token = result.Token || (result.TranzactionInfo && result.TranzactionInfo.TokenId) || null;
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || !env.PAY_WEBHOOK_SECRET) {
    return json({ error: 'apply_not_configured' }, 500);
  }
  const apply = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/apply_cardcom_test_payment', {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      authorization: 'Bearer ' + env.SUPABASE_ANON_KEY,
      'content-type': 'application/json',
      prefer: 'return=representation'
    },
    body: JSON.stringify({
      p_secret: env.PAY_WEBHOOK_SECRET,
      p_user: userId,
      p_amount: amount,
      p_tier_id: tierId,
      p_billing_cycle: cycle,
      p_lowprofile_id: lowProfileId,
      p_tranzaction_id: tranzactionId || null,
      p_token: token,
      p_invoice_doc_number: null,
      p_raw: { ResponseCode: result.ResponseCode, TranzactionId: tranzactionId, ReturnValue: ret, test: true }
    })
  });
  if (!apply.ok) {
    const err = await apply.text();
    return json({ error: 'apply_failed', detail: String(err).slice(0, 400) }, 500);
  }
  return json({ ok: true });
}
