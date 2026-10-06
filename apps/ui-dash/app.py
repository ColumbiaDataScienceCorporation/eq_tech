import dash
import plotly.graph_objects as go
from dash import dcc, html

from lib.auth.groups import FlaskGroupAuth
from lib.config.settings import get_settings

# url_base_pathname must match the ingress /dash prefix so /_dash-* routes stay under /dash/
app = dash.Dash(__name__, title="EQ Tech Analytics", url_base_pathname="/dash/")
settings = get_settings()

if settings.require_group_auth:
    auth = FlaskGroupAuth(settings.analysts_group_id, settings.admins_group_id)
    app.server.before_request(auth.before_request)


@app.server.route("/healthz")
def healthz():
    return "OK", 200


fig = go.Figure(go.Pie(
    labels=["AAPL", "MSFT", "GOOG", "AMZN"],
    values=[0.30, 0.25, 0.20, 0.25],
    hole=0.4,
))
fig.update_layout(title_text="Portfolio Allocation")

app.layout = html.Div([
    html.H1("EQ Tech Analytics Dashboard"),
    dcc.Graph(figure=fig),
])

server = app.server  # Expose Flask server for gunicorn

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8050, debug=False)
