DROP SCHEMA IF EXISTS q7 CASCADE; CREATE SCHEMA q7; SET search_path TO q7;

CREATE TABLE customers (customer_id SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE readings (
  reading_id SERIAL PRIMARY KEY, customer_id INT NOT NULL REFERENCES customers,
  reading_month DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
  UNIQUE (customer_id, reading_month));
CREATE TABLE bills (
  bill_id SERIAL PRIMARY KEY, reading_id INT NOT NULL UNIQUE REFERENCES readings,
  charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0, due_on DATE NOT NULL,
  CHECK (amount_paid >= 0 AND amount_paid <= charge));
CREATE TABLE receivable_snapshot (snapshot_date DATE PRIMARY KEY, total_due NUMERIC(14,2) NOT NULL);

CREATE FUNCTION trg_fn_reading_check() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) below previous_reading (%)', NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_reading_check BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_reading_check();

CREATE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC(12,2) AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN RAISE EXCEPTION 'Invalid consumption %', p_units; END IF;
  IF p_units <= 10 THEN RETURN ROUND(p_units * 5, 2); END IF;
  RETURN ROUND(50 + (p_units - 10) * 8, 2);
END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE) LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC;
BEGIN
  IF p_due_on IS NULL THEN RAISE EXCEPTION 'Due date required'; END IF;
  SELECT previous_reading, current_reading INTO v_prev, v_curr FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading %', p_reading_id; END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already billed', p_reading_id; END IF;
  INSERT INTO bills(reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END $$;

CREATE PROCEDURE pr_refresh_receivables() LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills
  ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

INSERT INTO customers(full_name) VALUES ('Lillian Mweemba'), ('Moses Kabwe'), ('Naomi Hamoonga');
INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading) VALUES
 (1,'2026-09-01',100,100), (1,'2026-10-01',100,110), (2,'2026-09-01',50,65),
 (2,'2026-10-01',65,90),   (3,'2026-09-01',10,15),   (3,'2026-10-01',15,25.5);
CALL pr_generate_bill(1, CURRENT_DATE-30); CALL pr_generate_bill(2, CURRENT_DATE-20);
CALL pr_generate_bill(3, CURRENT_DATE-10); CALL pr_generate_bill(4, CURRENT_DATE-5);
CALL pr_generate_bill(5, CURRENT_DATE+10); CALL pr_generate_bill(6, CURRENT_DATE+15);
UPDATE bills SET amount_paid = charge WHERE bill_id IN (1,2);
UPDATE bills SET amount_paid = 40 WHERE bill_id = 3;

CREATE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
  FROM bills b JOIN readings r ON r.reading_id = b.reading_id
               JOIN customers c ON c.customer_id = r.customer_id
 WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

CREATE INDEX idx_bills_unpaid_due ON bills(due_on) WHERE amount_paid < charge;
EXPLAIN SELECT bill_id, due_on FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE;

SELECT cron.schedule('q7_refresh_receivables', '30 0 * * *',
  $$SET search_path TO q7; CALL pr_refresh_receivables()$$);
