// Cardcom v11 LowProfile — NOT DEPLOYED.
// Env names only. Never put terminal numbers, API names, or passwords in this file.
//
// Required later (set in the Worker dashboard, by Ran):
//   CARDCOM_TERMINAL
//   CARDCOM_API_NAME
//   CARDCOM_API_PASSWORD
//   CARDCOM_PAPERLESS_TAX_EMAIL   // placeholder until a paperless.tax address exists
//   CARDCOM_WEBHOOK_PUBLIC_URL
//   PAYMENT_SUCCESS_URL
//   PAYMENT_FAILED_URL
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
//
// Docs: https://secure.cardcom.solutions/api/v11/LowProfile/Create
//       https://secure.cardcom.solutions/api/v11/LowProfile/GetLpResult

const CARDCOM_CREATE = 'https://secure.cardcom.solutions/api/v11/LowProfile/Create';
const CARDCOM_RESULT = 'https://secure.cardcom.solutions/api/v11/LowProfile/GetLpResult';

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  });
}

function configured(env) {
  return !!(env.CARDCOM_TERMINAL && env.CARDCOM_API_NAME);
}

function operationFor(cycle) {
  // Yearly one-time charge; monthly also creates a token for a standing order.
  return cycle === 'yearly' ? 'ChargeOnly' : 'ChargeAndCreateToken';
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, payments_configured: configured(env), deployed: false });
    }
    if (req.method === 'POST' && url.pathname === '/pay/create') {
      return createPayment(req, env);
    }
    if (req.method === 'POST' && url.pathname === '/pay/webhook') {
      return handleWebhook(req, env);
    }
    return json({ error: 'not found' }, 404);
  }
};

async function createPayment(req, env) {
  if (!configured(env)) {
    return json({ error: 'payments_not_configured', message: 'התשלום ייפתח בקרוב' }, 503);
  }
  let body;
  try { body = await req.json(); } catch { return json({ error: 'bad_json' }, 400); }
  const tierId = String(body.tier_id || '');
  const cycle = String(body.billing_cycle || '');
  const amount = Number(body.amount_ils);
  const userId = String(body.user_id || '');
  const productName = String(body.product_name || 'מסלול קהילה');
  const customerName = String(body.customer_name || '');
  const customerEmail = String(body.customer_email || '');
  if (!tierId || !userId || !(amount > 0) || (cycle !== 'monthly' && cycle !== 'yearly')) {
    return json({ error: 'bad_request' }, 400);
  }

  const emails = [customerEmail, env.CARDCOM_PAPERLESS_TAX_EMAIL].filter(Boolean).join(';');
  const payload = {
    TerminalNumber: Number(env.CARDCOM_TERMINAL),
    ApiName: env.CARDCOM_API_NAME,
    Operation: operationFor(cycle),
    Amount: Math.round(amount * 100) / 100,
    ReturnValue: `${userId}:${tierId}:${cycle}`.slice(0, 250),
    SuccessRedirectUrl: env.PAYMENT_SUCCESS_URL,
    FailedRedirectUrl: env.PAYMENT_FAILED_URL,
    WebHookUrl: env.CARDCOM_WEBHOOK_PUBLIC_URL,
    Language: 'he',
    ISOCoinId: 1,
    ProductName: productName.slice(0, 50),
    Document: {
      TypeToCreate: 'TaxInvoiceAndReceipt',
      Name: customerName || undefined,
      Email: emails || undefined,
      IsSendByEmail: true,
      Products: [{ Description: productName.slice(0, 50), Quantity: 1, UnitCost: Math.round(amount * 100) / 100 }]
    }
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
  return json({
    url: data.Url,
    lowprofile_id: data.LowProfileId,
    url_to_bit: cycle === 'yearly' ? (data.UrlToBit || null) : null
  });
}

async function handleWebhook(req, env) {
  if (!configured(env)) return json({ error: 'payments_not_configured' }, 503);
  let body;
  try { body = await req.json(); } catch {
    // Some Cardcom reports are form-encoded.
    const text = await req.text();
    try { body = Object.fromEntries(new URLSearchParams(text)); } catch { body = {}; }
  }
  const lowProfileId = body.LowProfileId || body.lowprofileid || body.lowProfileId;
  if (!lowProfileId) return json({ error: 'missing_lowprofile_id' }, 400);

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
    // Return 200 for known declines so Cardcom stops retrying; 500 only on our failure.
    return json({ ok: false, response_code: result.ResponseCode, description: result.Description });
  }

  const ret = String(result.ReturnValue || '');
  const [userId, tierId, cycle] = ret.split(':');
  const amount = Number(result.Amount || result.TranzactionInfo?.Amount || 0);
  const tranzactionId = String(result.TranzactionId || result.TransactionId || '');
  const token = result.Token || result.TranzactionInfo?.TokenId || null;
  const invoice = result.DocumentInfo?.DocumentNumber || result.DocumentNumber || null;

  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: 'supabase_not_configured' }, 500);
  }
  const apply = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/apply_cardcom_payment`, {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'content-type': 'application/json',
      prefer: 'return=representation'
    },
    // The live function lives in private; this public wrapper is added only when payments are turned on.
    // Until then the Worker is not deployed. Prefer calling private.apply_cardcom_payment via SQL as service_role.
    body: JSON.stringify({
      p_user: userId,
      p_amount: amount,
      p_tier_id: tierId,
      p_billing_cycle: cycle,
      p_lowprofile_id: lowProfileId,
      p_tranzaction_id: tranzactionId,
      p_token: token,
      p_invoice_doc_number: invoice ? String(invoice) : null,
      p_raw: result
    })
  });

  // Service role should invoke the private function through a SQL endpoint or a future public wrapper
  // granted only to service_role. If the REST path is not exposed, use:
  //   POST /rest/v1/rpc/... is public-schema only. Deploy-time option: a thin public wrapper
  //   with no grants to anon/authenticated, executed as service_role (bypasses grants in practice
  //   via the service role connection). Until deploy, this file is reference only.
  if (!apply.ok) {
    const err = await apply.text();
    return json({ error: 'apply_failed', detail: err.slice(0, 500) }, 500);
  }
  return json({ ok: true });
}
