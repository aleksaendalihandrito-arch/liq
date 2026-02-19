from websocket import WebSocketApp
import json
import time
import requests
import os  # Добавляем для переменных окружения
from datetime import datetime

# Настройки - БЕРЕМ ИЗ ПЕРЕМЕННЫХ ОКРУЖЕНИЯ
TELEGRAM_BOT_TOKEN = os.environ.get('TELEGRAM_BOT_TOKEN', '7572230525:AAFzAQsMe4DlTYAA8G5UgGnYH598ZxgZOjs')
TELEGRAM_CHAT_ID = os.environ.get('TELEGRAM_CHAT_ID', '5296533274')
LIQUIDATION_THRESHOLD = int(os.environ.get('LIQUIDATION_THRESHOLD', 50000))
TEST_MODE = os.environ.get('TEST_MODE', 'False').lower() == 'true'

# Топ-25 монет по рыночной капитализации
TOP_25_COINS = {
    'BTCUSDT', 'ETHUSDT', 'BNBUSDT', 'SOLUSDT', 'XRPUSDT',
    'ADAUSDT', 'DOGEUSDT', 'AVAXUSDT', 'DOTUSDT', 'LINKUSDT',
    'MATICUSDT', 'SHIBUSDT', 'LTCUSDT', 'BCHUSDT', 'ATOMUSDT',
    'UNIUSDT', 'XLMUSDT', 'XMRUSDT', 'ETCUSDT', 'FILUSDT',
    'APTUSDT', 'HBARUSDT', 'NEARUSDT', 'VETUSDT', 'OPUSDT', 'BTCUSDC'
}

def log(message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}", flush=True)  # Добавляем flush=True для Railway

def generate_links(symbol):
    """Генерация ссылок на аналитические ресурсы"""
    clean_symbol = symbol.replace('USDT', '').replace('1000', '')
    return {
        'coinglass': f"https://www.coinglass.com/pro/futures/LiquidationHeatMapModel3?coin={clean_symbol}&type=pair",
        'tradingview': f"https://www.tradingview.com/chart/?symbol=BINANCE:{symbol}",
        'binance': f"https://www.binance.com/ru/trade/{symbol}",
        'bybit': f"https://www.bybit.com/trade/usdt/{symbol}"
    }

def send_telegram_alert(message, symbol):
    try:
        log(f"Отправка: {message[:50]}...")

        links = generate_links(symbol)
        message_with_links = (
            f"{message}\n\n"
            f"🔗 <b>Быстрый анализ:</b>\n"
            f"• 📊 <a href='{links['coinglass']}'>Coinglass</a>\n"
            f"• 📈 <a href='{links['tradingview']}'>TradingView</a>\n"
            f"• 💰 <a href='{links['binance']}'>Binance</a>\n"
            f"• ⚡ <a href='{links['bybit']}'>Bybit</a>"
        )

        monospace_symbol = f"<code>{symbol}</code>"
        message_with_links = message_with_links.replace(symbol, monospace_symbol)

        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
        payload = {
            'chat_id': TELEGRAM_CHAT_ID,
            'text': message_with_links,
            'parse_mode': 'HTML',
            'disable_web_page_preview': False
        }
        response = requests.post(url, json=payload, timeout=10)
        response.raise_for_status()
        log("Сообщение отправлено в Telegram")
        return True
    except Exception as e:
        log(f"ОШИБКА Telegram: {str(e)}")
        return False

def is_top_coin(symbol):
    """Проверяем, является ли монета топ-25"""
    return symbol in TOP_25_COINS

def on_message(ws, message):
    try:
        log(f"Получены данные: {message[:100]}...")
        data = json.loads(message)

        if TEST_MODE:
            log("Тестовый режим: отправка fake-ликвидации")
            test_message = (
                f"⚡️ <b>ТЕСТОВОЕ УВЕДОМЛЕНИЕ</b>\n"
                f"Сторона: 🔴 SHORT\n"
                f"Сумма: $999,999\n"
                f"Время: {datetime.now().strftime('%H:%M:%S')}"
            )
            send_telegram_alert(test_message, "TESTUSDT")
            return

        if 'e' in data and data['e'] == 'forceOrder':
            liq = data['o']
            symbol = liq.get('s', 'UNKNOWN')

            if is_top_coin(symbol):
                log(f"Игнорируем топ-монету: {symbol}")
                return

            side = liq.get('S')
            quantity = float(liq.get('q', 0))
            price = float(liq.get('ap', 0))
            usd_value = quantity * price
            time_stamp = datetime.fromtimestamp(data.get('E', 0) / 1000).strftime('%H:%M:%S')

            log(f"Обработка: {symbol} {side} ${usd_value:,.0f}")

            if side == 'BUY' and usd_value >= LIQUIDATION_THRESHOLD:
                msg = (
                    f"📈 <b>Рост цены + Ликвидация SHORT</b>\n"
                    f"Монета: <code>{symbol}</code>\n"
                    f"🔴 Ликвидировано SHORT: <code>${usd_value:,.0f}</code>\n"
                    f"💰 Цена ликвидации: <code>{price:.2f}</code>\n"
                    f"🕒 Время: <code>{time_stamp}</code>\n"
                    f"📊 Не топ-25 монета"
                )
                send_telegram_alert(msg, symbol)
            else:
                if side != 'BUY':
                    log(f"Игнорируем LONG ликвидацию (падение цены): {symbol}")
                else:
                    log("Ликвидация ниже порога, игнорируем")

    except Exception as e:
        log(f"КРИТИЧЕСКАЯ ОШИБКА: {str(e)}")

def on_error(ws, error):
    log(f"ОШИБКА WebSocket: {str(error)}")
    time.sleep(5)

def on_close(ws, close_status_code, close_msg):
    log(f"Соединение закрыто. Код: {close_status_code}, Причина: {close_msg}")
    time.sleep(2)

def on_open(ws):
    log("Успешное подключение к Binance WebSocket")
    send_telegram_alert(
        "🔌 Бот запущен и подключен к Binance\n\n📈 Отслеживаю SHORT ликвидации (когда цена растет) для НЕ топ-25 монет",
        "SYSTEM")
    if TEST_MODE:
        log("Тестовый режим активирован")

def connect_websocket():
    log("Попытка подключения к WebSocket...")
    while True:  # Бесконечный цикл переподключения
        try:
            ws = WebSocketApp("wss://fstream.binance.com/ws/!forceOrder@arr",
                              on_open=on_open,
                              on_message=on_message,
                              on_error=on_error,
                              on_close=on_close)
            ws.run_forever()
        except Exception as e:
            log(f"ОШИБКА ПОДКЛЮЧЕНИЯ: {str(e)}")
        log("Переподключение через 5 секунд...")
        time.sleep(5)

if __name__ == "__main__":
    log("=" * 50)
    log("ЗАПУСК БОТА ЛИКВИДАЦИЙ НА RAILWAY")
    log("=" * 50)
    log(f"Игнорируемые монеты: {len(TOP_25_COINS)} топовых")
    log(f"Порог ликвидации: ${LIQUIDATION_THRESHOLD}")
    log(f"Режим тестирования: {TEST_MODE}")

    try:
        import websocket
        log("✓ Библиотека websocket загружена")
    except ImportError as e:
        log(f"✗ ОШИБКА: Не установлены зависимости - {str(e)}")
        exit(1)

    connect_websocket()
