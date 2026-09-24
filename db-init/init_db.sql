-- =========================================================================
-- PROYECTO: La Castellana - Sistema de Inventario
-- =========================================================================

-- =========================================================================
-- CREACIÓN DE TABLAS DDL CON RESTRICCIONES Y CLAVES
-- =========================================================================

-- Módulo de Autenticación
CREATE TABLE roles (
    id_rol SERIAL PRIMARY KEY, -- SERIAL crea un ID numérico que se autoincrementa solo
    nombre_rol VARCHAR(50) UNIQUE NOT NULL, -- UNIQUE evita que existan dos roles con el mismo nombre
    descripcion TEXT
);

CREATE TABLE usuarios (
    id_usuario SERIAL PRIMARY KEY,
    id_rol INT NOT NULL, -- Llave foránea para conectar con la tabla roles
    correo VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    estado BOOLEAN DEFAULT TRUE, -- Por defecto, todo usuario nuevo está activo
    fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Guarda automáticamente la fecha y hora actual
    -- crea la relación: Si intentan borrar un rol que tiene usuarios, RESTRICT lo impide por seguridad.
    CONSTRAINT fk_rol FOREIGN KEY (id_rol) REFERENCES roles(id_rol) ON DELETE RESTRICT 
);

-- Módulo de Catálogo e Inventario
CREATE TABLE categorias (
    id_categoria SERIAL PRIMARY KEY,
    nombre VARCHAR(100) UNIQUE NOT NULL,
    activa BOOLEAN DEFAULT TRUE
);

CREATE TABLE productos (
    id_producto SERIAL PRIMARY KEY,
    codigo_sku VARCHAR(50) UNIQUE NOT NULL, -- El SKU es el código único de barras/identificador del producto
    id_categoria INT NOT NULL,
    nombre VARCHAR(150) NOT NULL,
    descripcion TEXT,
    -- CHECK asegura que no se puedan ingresar precios negativos o de valor cero
    precio_unitario DECIMAL(10, 2) NOT NULL CHECK (precio_unitario > 0), 
    -- CHECK asegura que el stock nunca sea negativo
    stock_actual INT DEFAULT 0 CHECK (stock_actual >= 0), 
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_categoria FOREIGN KEY (id_categoria) REFERENCES categorias(id_categoria) ON DELETE RESTRICT
);

CREATE TABLE movimientos_inventario (
    id_movimiento SERIAL PRIMARY KEY,
    id_producto INT NOT NULL,
    id_usuario INT NOT NULL, -- Registra qué usuario hizo el movimiento
    -- CHECK obliga a que solo se pueda escribir 'ENTRADA' o 'SALIDA', evitando errores de tipeo
    tipo_movimiento VARCHAR(10) NOT NULL CHECK (tipo_movimiento IN ('ENTRADA', 'SALIDA')), 
    cantidad INT NOT NULL CHECK (cantidad > 0), -- No se pueden mover cantidades negativas o cero
    fecha_movimiento TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    observaciones TEXT,
    -- CASCADE: Si se borra un producto, se borra su historial de movimientos
    CONSTRAINT fk_producto FOREIGN KEY (id_producto) REFERENCES productos(id_producto) ON DELETE CASCADE,
    CONSTRAINT fk_usuario_mov FOREIGN KEY (id_usuario) REFERENCES usuarios(id_usuario) ON DELETE RESTRICT
);

-- =========================================================================
-- VISTAS 
-- =========================================================================
-- Las vistas son consultas guardadas. Esta vista une la tabla productos y categorías 
-- para que el Frontend la consuma fácilmente sin hacer consultas complejas.
CREATE VIEW vw_catalogo_productos AS
SELECT 
    p.codigo_sku,
    p.nombre AS producto,
    c.nombre AS categoria,
    p.precio_unitario,
    p.stock_actual,
    (p.precio_unitario * p.stock_actual) AS valor_total_inventario -- Columna calculada en el momento
FROM productos p
INNER JOIN categorias c ON p.id_categoria = c.id_categoria
WHERE c.activa = TRUE; -- Solo muestra productos de categorías activas

-- =========================================================================
-- FUNCIONES Y DISPARADORES
-- =========================================================================
-- Esta función contiene la lógica matemática para sumar o restar stock
CREATE OR REPLACE FUNCTION fn_actualizar_stock()
RETURNS TRIGGER AS $$
BEGIN
    -- Si el movimiento es ENTRADA, suma la cantidad al stock del producto
    IF NEW.tipo_movimiento = 'ENTRADA' THEN
        UPDATE productos 
        SET stock_actual = stock_actual + NEW.cantidad 
        WHERE id_producto = NEW.id_producto;
    -- Si el movimiento es SALIDA, resta la cantidad
    ELSIF NEW.tipo_movimiento = 'SALIDA' THEN
        -- Validación de seguridad: Verifica que haya suficiente stock antes de restar
        IF (SELECT stock_actual FROM productos WHERE id_producto = NEW.id_producto) < NEW.cantidad THEN
            RAISE EXCEPTION 'Stock insuficiente para realizar la salida.'; -- Lanza error si no hay stock
        END IF;
        
        UPDATE productos 
        SET stock_actual = stock_actual - NEW.cantidad 
        WHERE id_producto = NEW.id_producto;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Este trigger escucha a la tabla movimientos_inventario. 
-- Cada vez que se inserta  un nuevo movimiento, ejecuta la función de arriba automáticamente.
CREATE TRIGGER trg_movimiento_stock
AFTER INSERT ON movimientos_inventario
FOR EACH ROW
EXECUTE FUNCTION fn_actualizar_stock();

-- =========================================================================
-- PROCEDIMIENTOS ALMACENADOS
-- =========================================================================
-- Los procedimientos almacenados agrupan varias instrucciones en una sola llamada segura
CREATE OR REPLACE PROCEDURE sp_registrar_producto_completo(
    p_nombre_categoria VARCHAR,
    p_sku VARCHAR,
    p_nombre_producto VARCHAR,
    p_precio DECIMAL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_categoria INT;
BEGIN
    -- Paso 1: Busca si la categoría ya existe en la base de datos
    SELECT id_categoria INTO v_id_categoria FROM categorias WHERE nombre = p_nombre_categoria;
    
    -- Paso 2: Si no existe, la crea e inserta su nuevo ID en la variable
    IF NOT FOUND THEN
        INSERT INTO categorias (nombre) VALUES (p_nombre_categoria) RETURNING id_categoria INTO v_id_categoria;
    END IF;

    -- Paso 3: Inserta el producto utilizando el ID de la categoría encontrada o recién creada
    INSERT INTO productos (codigo_sku, id_categoria, nombre, precio_unitario)
    VALUES (p_sku, v_id_categoria, p_nombre_producto, p_precio);
    
    COMMIT; -- Confirma la transacción guardando los datos definitivamente
END;
$$;