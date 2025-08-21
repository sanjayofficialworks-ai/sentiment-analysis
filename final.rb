require 'sinatra'
require 'net/http'
require 'json'
require 'uri'

set :port, 3000

API_BASE = "http://localhost:5000"

helpers do
  def fmt(v, d="N/A"); v.nil? ? d : v; end

  def api_get(path)
    uri = URI("#{API_BASE}#{path}")
    res = Net::HTTP.get_response(uri)
    if res.code == '200' && res['Content-Type']&.include?('application/json')
      JSON.parse(res.body)
    else
      { "error" => "GET #{path} -> #{res.code} #{res.message}", "raw" => res.body.to_s }
    end
  rescue => e
    { "error" => e.message }
  end

  def api_post(path, payload)
    uri = URI("#{API_BASE}#{path}")
    req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" })
    req.body = payload.to_json
    res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
    if res.code == '200' && res['Content-Type']&.include?('application/json')
      JSON.parse(res.body)
    else
      { "error" => "POST #{path} -> #{res.code} #{res.message}", "raw" => res.body.to_s }
    end
  rescue => e
    { "error" => e.message }
  end
end

get '/' do
  @ticker = params[:symbol] || "AAPL"

  # Stock data
  stock = api_get("/stock/#{@ticker}")
  if stock["error"]
    @error = stock["error"]
  else
    @live_price = stock["live_price"]
    @beta = stock["beta"]
    @id_risk = stock["idiosyncratic_risk"]
    @sentiment_impact = stock["sentiment_impact"]
    @notes = stock["notes"]
    @trend = stock["sentiment_trend_10_day"] || {}
  end

  # News data (past 10 days, already scored by backend)
  unless @error
    news = api_get("/news/#{@ticker}")
    @news_items = news["items"].is_a?(Array) ? news["items"] : []
  end

  # Custom user news text
  @user_text = params[:user_text]
  @user_result = nil
  if @user_text && @user_text.strip.size > 0 && !@error
    @user_result = api_post("/analyze_news", { text: @user_text, symbol: @ticker })
  end

  erb :index
end

__END__

@@index
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Stock Sentiment Dashboard</title>
  <style>
    body {
      font-family: 'Segoe UI', sans-serif;
      background-color: #101010;
      color: #f4f4f4;
      padding: 20px;
    }
    .container {
      max-width: 1100px;
      margin: auto;
      background-color: #1a1a1a;
      padding: 30px;
      border-radius: 12px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.7);
    }
    h1 {
      color: #ff004f;
    }
    input, button, textarea {
      padding: 10px;
      border-radius: 5px;
      border: none;
      margin: 5px 0;
    }
    input {
      width: 200px;
    }
    button {
      background-color: #ff004f;
      color: white;
      cursor: pointer;
    }
    button:hover {
      background-color: #e6003d;
    }
    textarea {
      width: 100%;
      background-color: #2a2a2a;
      color: #f4f4f4;
      border: 1px solid #444;
    }
    .section {
      margin-top: 30px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 10px;
    }
    table, th, td {
      border: 1px solid #444;
    }
    th, td {
      padding: 10px;
      text-align: left;
    }
    th {
      background-color: #2a2a2a;
    }
    iframe {
      margin-top: 20px;
      border-radius: 8px;
      width: 100%;
      height: 400px;
      border: none;
    }
    .muted {
      color: #bbb;
      font-size: 0.9em;
    }
    a {
      color: #9ad;
    }
    .error {
      color: #ff6b6b;
      background-color: #2a1a1a;
      padding: 10px;
      border-radius: 5px;
      border: 1px solid #ff4444;
    }
    .success {
      color: #51cf66;
      background-color: #1a2a1a;
      padding: 10px;
      border-radius: 5px;
      border: 1px solid #44ff44;
    }
    .result-box {
      background-color: #2a2a2a;
      padding: 15px;
      border-radius: 8px;
      margin-top: 10px;
      border: 1px solid #444;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>🚀 Stock Sentiment Dashboard</h1>
    
    <form method="get" action="/">
      <label for="symbol">Enter Stock Symbol:</label>
      <input type="text" name="symbol" id="symbol" value="<%= @ticker %>" required>
      <button type="submit">Analyze Stock</button>
    </form>

    <% if @error %>
      <div class="error">
        <h3>⚠️ Error</h3>
        <p><%= @error %></p>
        <p class="muted">Make sure the FastAPI backend is running on http://localhost:5000</p>
      </div>
    <% else %>
      <div class="section">
        <h2>📊 Live Market Data for <%= @ticker.upcase %></h2>
        <ul>
          <li><strong>Live Price:</strong> $<%= fmt(@live_price) %></li>
          <li><strong>Beta:</strong> <%= fmt(@beta) %></li>
          <li><strong>Idiosyncratic Risk:</strong> <%= fmt(@id_risk) %></li>
          <li><strong>Sentiment Impact:</strong> <%= fmt(@sentiment_impact) %>%</li>
          <li><strong>Market Notes:</strong> <%= fmt(@notes) %></li>
        </ul>
      </div>

      <div class="section">
        <h2>📈 10-Day Sentiment Trend</h2>
        <ul>
          <li>🔼 Bullish: <%= fmt(@trend["bullish"]) %></li>
          <li>🔽 Bearish: <%= fmt(@trend["bearish"]) %></li>
          <li>➖ Neutral: <%= fmt(@trend["neutral"]) %></li>
          <li>🧠 Overall Sentiment: <%= fmt(@trend["dominant_sentiment"]) %></li>
        </ul>
      </div>

      <div class="section">
        <h2>🗞️ Latest News Sentiment (Past 10 Days) for <%= @ticker.upcase %></h2>
        <p class="muted">Headlines pulled from Yahoo Finance and Google News RSS, scored by FinBERT.</p>
        <% if @news_items.any? %>
          <table>
            <tr>
              <th>Headline</th>
              <th>Sentiment</th>
              <th>Confidence</th>
              <th>Published</th>
            </tr>
            <% @news_items.each do |news| %>
              <tr>
                <td><a href="<%= news["link"] %>" target="_blank"><%= news["headline"] %></a></td>
                <td><%= news["sentiment"] %></td>
                <td><%= ((news["confidence"].to_f) * 100).round(2) %>%</td>
                <td><%= news["published"] %></td>
              </tr>
            <% end %>
          </table>
        <% else %>
          <p class="muted">No recent news found for <%= @ticker.upcase %>.</p>
        <% end %>
      </div>

      <div class="section">
        <h2>📝 Analyze Your Own News Text</h2>
        <form method="get" action="/">
          <input type="hidden" name="symbol" value="<%= @ticker %>">
          <textarea name="user_text" rows="4" placeholder="Paste a headline or news paragraph for <%= @ticker.upcase %>..."><%= @user_text %></textarea>
          <br>
          <button type="submit">Analyze Custom News</button>
        </form>

        <% if @user_result %>
          <% if @user_result["error"] %>
            <div class="error">
              <h3>Analysis Error</h3>
              <p><%= @user_result["error"] %></p>
              <% if @user_result["raw"] %>
                <p class="muted">Backend response: <%= @user_result["raw"] %></p>
              <% end %>
            </div>
          <% else %>
            <div class="result-box success">
              <h3>✅ Analysis Result</h3>
              <ul>
                <li><strong>User Sentiment:</strong> <%= @user_result["user_sentiment"] %> (<%= (@user_result["user_score"].to_f*100).round(1) %>% confidence)</li>
              </ul>
            </div>
            <div class="result-box">
              <h3>🧠 Summary of Stock and Impact on Coherent System</h3>
              <p><%= @user_result["impact_summary_plain_english"] %></p>
            </div>
          <% end %>
        <% end %>
      </div>

      <div class="section">
        <h2>📉 Live Stock Chart</h2>
        <iframe 
          src="https://s.tradingview.com/widgetembed/?symbol=<%= @ticker %>&interval=D&hidesidetoolbar=1&symboledit=1&saveimage=1&toolbarbg=f1f3f6&studies=[]&theme=dark&style=1&timezone=Etc/UTC&withdateranges=1&hidevolume=false&hideideas=1&widgetbar=show&enable_publishing=false"
          allowtransparency="true"
          scrolling="no">
        </iframe>
      </div>
    <% end %>
  </div>
</body>
</html>