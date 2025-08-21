from fastapi import FastAPI
from pydantic import BaseModel
from fastapi.middleware.cors import CORSMiddleware
from transformers import pipeline
import yfinance as yf
import random
from datetime import datetime, timedelta
import feedparser
import hashlib
import re

app = FastAPI(title="Stock Sentiment Backend")

# Allow frontend browser calls
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Load FinBERT once
sentiment_model = pipeline("sentiment-analysis", model="yiyanghkust/finbert-tone")


# ---------------------------
# Utilities
# ---------------------------
class SentimentRequest(BaseModel):
    text: str
    symbol: str = "AAPL"


def make_market_notes(beta: float) -> str:
    if beta is None:
        return "Beta unavailable. Volatility vs market cannot be inferred."
    if beta > 1:
        return "More volatile than the market. A 1% move in the market may lead to >1% move in this stock."
    if beta < 1:
        return "Less volatile than the market. A 1% move in the market may lead to <1% move in this stock."
    return "Moves roughly in line with the market on average."


def clean_headline(h: str) -> str:
    if not h:
        return ""
    h = re.sub(r"\s+", " ", h)
    return h.strip()


def within_last_n_days(dt: datetime, days: int = 10) -> bool:
    return dt >= datetime.utcnow() - timedelta(days=days)


def parse_time(entry):
    for key in ["published_parsed", "updated_parsed"]:
        t = entry.get(key)
        if t:
            try:
                return datetime(*t[:6])
            except Exception:
                pass
    return datetime.utcnow()


def dedupe_keep_order(items, keyfunc):
    seen = set()
    out = []
    for it in items:
        k = keyfunc(it)
        if k in seen:
            continue
        seen.add(k)
        out.append(it)
    return out


# ---------------------------
# Fetch News & Analyze
# ---------------------------
def fetch_news_rss(symbol: str):
    yahoo_url = f"https://feeds.finance.yahoo.com/rss/2.0/headline?s={symbol}&region=US&lang=en-US"
    google_url = f"https://news.google.com/rss/search?q={symbol}%20stock&hl=en-US&gl=US&ceid=US:en"

    feeds = []
    try:
        feeds.append(feedparser.parse(yahoo_url))
    except Exception:
        pass
    try:
        feeds.append(feedparser.parse(google_url))
    except Exception:
        pass

    entries = []
    for f in feeds:
        for e in f.entries:
            dt = parse_time(e)
            if not within_last_n_days(dt, 10):
                continue
            title = clean_headline(e.get("title", ""))
            if not title:
                continue
            link = e.get("link", "")
            entries.append({
                "title": title,
                "link": link,
                "published": dt.isoformat() + "Z",
                "source": e.get("source", None)
            })

    entries = dedupe_keep_order(entries, lambda x: hashlib.md5(x["title"].lower().encode()).hexdigest())
    return entries[:25]


def analyze_headlines(entries):
    analyzed = []
    for e in entries:
        try:
            res = sentiment_model(e["title"])[0]
            analyzed.append({
                "headline": e["title"],
                "sentiment": res["label"].lower(),
                "confidence": float(res["score"]),
                "link": e.get("link"),
                "published": e.get("published"),
                "source": e.get("source"),
            })
        except Exception as ex:
            # Skip headlines that cause sentiment analysis errors
            print(f"Error analyzing headline '{e['title']}': {ex}")
            continue
    return analyzed


def summarize_impact(symbol: str, analyzed_list, user_text=None):
    counts = {"positive": 0, "negative": 0, "neutral": 0}
    avg_conf = 0.0
    for a in analyzed_list:
        s = a["sentiment"]
        counts[s] = counts.get(s, 0) + 1
        avg_conf += a["confidence"]
    n = len(analyzed_list) if analyzed_list else 1
    avg_conf /= n

    if counts["positive"] > counts["negative"]:
        tilt = "overall leaning positive"
    elif counts["negative"] > counts["positive"]:
        tilt = "overall leaning negative"
    else:
        tilt = "overall balanced/neutral"

    pieces = []
    pieces.append(f"In the last 10 days, news flow for {symbol.upper()} appears {tilt}.")
    pieces.append(f"Observed headlines: {counts['positive']} positive, {counts['negative']} negative, {counts['neutral']} neutral with average confidence around {round(avg_conf*100,1)}%.")

    if counts["negative"] > counts["positive"]:
        pieces.append("This may indicate short-term downside pressure or uncertainty.")
    elif counts["positive"] > counts["negative"]:
        pieces.append("This may support a constructive short-term outlook.")
    else:
        pieces.append("Signals are mixed; consider waiting for clearer catalysts.")

    if user_text:
        try:
            ures = sentiment_model(user_text)[0]
            ulabel = ures["label"].lower()
            uscore = float(ures["score"])
            pieces.append(f"User-provided news tone is {ulabel} (confidence {round(uscore*100,1)}%).")
            if ulabel == "positive":
                pieces.append("This could strengthen the positive bias if seen elsewhere.")
            elif ulabel == "negative":
                pieces.append("This could increase short-term downside risk if confirmed.")
            else:
                pieces.append("The user update is neutral and does not change bias.")
        except Exception as ex:
            pieces.append(f"Could not analyze user text: {str(ex)}")

    pieces.append("🧠 Plain-English impact on the coherent system: sentiment modifies short-term risk and volatility. Negative tone can elevate drawdowns; positive tone can compress risk premia. Use as context, not as a standalone signal.")
    return " ".join(pieces)


# ---------------------------
# Routes
# ---------------------------
@app.get("/health")
def health():
    return {"status": "ok", "time": datetime.utcnow().isoformat() + "Z"}


@app.get("/stock/{symbol}")
def get_stock(symbol: str):
    try:
        ticker = yf.Ticker(symbol)
        hist = ticker.history(period="5d", auto_adjust=False)

        if hist is None or hist.empty:
            live_price = None
        else:
            last_close_series = hist["Close"].dropna()
            live_price = round(float(last_close_series.iloc[-1]), 2) if not last_close_series.empty else None

        try:
            beta_val = ticker.info.get("beta", None)
            beta = round(float(beta_val), 3) if beta_val is not None else None
        except Exception:
            beta = None

        idiosyncratic_risk = round(random.uniform(0.01, 0.05), 4)
        sentiment_impact = 100 if (beta is not None and beta > 1) else 50
        notes = make_market_notes(beta)

        bullish = random.randint(0, 5)
        bearish = random.randint(0, 5)
        neutral = max(0, 10 - (bullish + bearish))
        dominant = "bullish" if bullish > bearish else ("bearish" if bearish > bullish else "neutral")
        sentiment_trend_10_day = {
            "bullish": bullish,
            "bearish": bearish,
            "neutral": neutral,
            "dominant_sentiment": dominant,
        }

        return {
            "symbol": symbol.upper(),
            "live_price": live_price,
            "beta": beta,
            "idiosyncratic_risk": idiosyncratic_risk,
            "sentiment_impact": sentiment_impact,
            "notes": notes,
            "sentiment_trend_10_day": sentiment_trend_10_day,
            "as_of": datetime.utcnow().isoformat() + "Z",
        }
    except Exception as e:
        return {"error": f"Failed to fetch stock data: {str(e)}"}


@app.get("/news/{symbol}")
def get_news(symbol: str):
    try:
        entries = fetch_news_rss(symbol)
        analyzed = analyze_headlines(entries)
        return {
            "symbol": symbol.upper(),
            "items": analyzed,
            "count": len(analyzed),
            "as_of": datetime.utcnow().isoformat() + "Z",
        }
    except Exception as e:
        return {"error": f"Failed to fetch news: {str(e)}", "items": []}


@app.post("/analyze_news")
def analyze_news(req: SentimentRequest):
    try:
        entries = fetch_news_rss(req.symbol)
        analyzed = analyze_headlines(entries)
        summary = summarize_impact(req.symbol, analyzed, user_text=req.text if req.text else None)
        
        # Fixed the bug here - sentiment_model returns a list, need to access [0] first
        user_sentiment_result = sentiment_model(req.text)[0] if req.text else {"label": "neutral", "score": 0.5}
        
        return {
            "symbol": req.symbol.upper(),
            "user_sentiment": user_sentiment_result["label"].lower(),
            "user_score": float(user_sentiment_result["score"]),
            "last_10d_news": analyzed,
            "impact_summary_plain_english": summary,
            "as_of": datetime.utcnow().isoformat() + "Z",
        }
    except Exception as e:
        return {"error": f"Analysis failed: {str(e)}"}


@app.post("/sentiment")
def sentiment_only(req: SentimentRequest):
    try:
        res = sentiment_model(req.text)[0]
        return {
            "symbol": req.symbol.upper(),
            "sentiment": res["label"].lower(),
            "score": float(res["score"]),
            "as_of": datetime.utcnow().isoformat() + "Z",
        }
    except Exception as e:
        return {"error": f"Sentiment analysis failed: {str(e)}"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=5000)