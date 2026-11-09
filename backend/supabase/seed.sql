-- Seed data: categories and a small set of common brands (free-text brands remain allowed).
insert into public.categories (slug, name, sort_order) values
  ('electronics', 'Electronics', 10),
  ('appliances', 'Appliances', 20),
  ('computers', 'Computers', 30),
  ('phones_tablets', 'Phones & Tablets', 40),
  ('gaming', 'Gaming', 50),
  ('audio', 'Audio', 60),
  ('cameras', 'Cameras', 70),
  ('furniture', 'Furniture', 80),
  ('tools', 'Tools', 90),
  ('automotive', 'Automotive', 100),
  ('home', 'Home', 110),
  ('kitchen', 'Kitchen', 120),
  ('wearables', 'Wearables', 130),
  ('other', 'Other', 999)
on conflict (slug) do nothing;

-- Brand support/registration URLs must be verified before launch (last_verified_at stays NULL until then).
insert into public.brands (name) values
  ('Apple'), ('Samsung'), ('LG'), ('Sony'), ('Dyson'), ('Bosch'), ('Whirlpool'), ('GE Appliances'),
  ('DeWalt'), ('Milwaukee'), ('Makita'), ('KitchenAid'), ('Dell'), ('HP'), ('Lenovo'), ('Microsoft'),
  ('Nintendo'), ('Bose'), ('Canon'), ('Nikon'), ('Breville'), ('iRobot'), ('Shark'), ('Frigidaire')
on conflict (normalized_name) do nothing;
