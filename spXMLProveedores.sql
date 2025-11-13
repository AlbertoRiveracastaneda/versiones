USE OAM
GO
SET ANSI_NULLS, QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE dbo.spXMLProveedores
	@Empresa			VARCHAR(5),
	@RutaXML			VARCHAR(255),
	@Clave				VARCHAR(10),
	@Tipo				VARCHAR(20),
	@NombreArchivo		VARCHAR(255),
	@ID					INT = NULL OUTPUT,
	@Ok					INT = NULL OUTPUT,
	@OkRef				VARCHAR(255) = NULL OUTPUT,
	@IDReembolsoGastos	INT = NULL
WITH ENCRYPTION
AS
BEGIN
	DECLARE @Archivo				VARCHAR(MAX),
			@iDatos					INT,
			@PrefijoCFDI			VARCHAR(800),
			@UUID					VARCHAR(36),
			@RFCEmisor				VARCHAR(15),
			@RFCReceptor			VARCHAR(15),
			@RutaArchivo			VARCHAR(800),
			@RFCEmpresa				VARCHAR(15),
			@RFCCliente				VARCHAR(15),
			@Inicial				INT,
			@Adicional				XML,
			@TasaOCuota				DECIMAL(18,6),
			@ImpuestoDetalle		MONEY,
			@TipoDeComprobante		VARCHAR(5),
			@Impuesto1				VARCHAR(5) = '002',
			@ImporteImpuesto1		MONEY,
			@Impuesto2				VARCHAR(5) = '003',
			@TasaOCuota2			DECIMAL(18,6),			
			@ImporteImpuesto2		MONEY,
			@Retencion1				VARCHAR(5) = '001',
			@RTasaOCuota1			DECIMAL(18,6),
			@ImporteRetencion1		MONEY,
			@Retencion2				VARCHAR(5) = '002',
			@RTasaOCuota2			DECIMAL(18,6),
			@ImporteRetencion2		MONEY,
			@DiasVigenciaFactura	INT,
			@FechaTimbrado			DATETIME,
			@WAsignaSucursal		BIT,
			@Estatus				VARCHAR(50)

	DECLARE @Detalle TABLE(Renglon					INT IDENTITY(1, 1),
							ClaveProdServ			VARCHAR(20),
							NoIdentificacion		VARCHAR(100),
							Descripcion				VARCHAR(1000),
							Cantidad				FLOAT,
							ValorUnitario			MONEY,
							Importe					MONEY,
							TasaOCuota				DECIMAL(18,6),
							ImporteImpuestoTotal	MONEY,
							Descuento				MONEY,
							Adicional				VARCHAR(4000),
							Exento					BIT,
							Impuesto1				VARCHAR(5),
							ImporteImpuesto1		MONEY,
							Impuesto2				VARCHAR(5),
							TasaOCuota2				DECIMAL(18,6),							
							ImporteImpuesto2		MONEY, 
							Retencion1				VARCHAR(5),
							RTasaOCuota1			DECIMAL(18,6),
							ImporteRetencion1		MONEY,
							Retencion2				VARCHAR(5),
							RTasaOCuota2			DECIMAL(18,6),
							ImporteRetencion2		MONEY)

	SELECT @RFCEmpresa = ISNULL(RFC, '')
	FROM Empresa
	WHERE Empresa = @Empresa

	SELECT @RFCCliente = ISNULL(RFC, ''), @DiasVigenciaFactura = ISNULL(NULLIF(DiasVigenciaFactura, 0), 60), @WAsignaSucursal = ISNULL(WAsignaSucursal, 0)
	FROM Prov
	WHERE Proveedor = @Clave

	IF @WAsignaSucursal = 1
		SELECT @Estatus = 'Pendiente de Asignar Unidad'
	ELSE 
		SELECT @Estatus = 'Pendiente de Recepción en Unidad'

	SELECT @RutaArchivo = @RutaXML + '\' + @NombreArchivo
	EXEC spLeerArchivo @RutaArchivo, @Archivo OUTPUT, @Ok OUTPUT, @OkRef OUTPUT

	BEGIN TRANSACTION  

	IF NULLIF(@Archivo, '') IS NOT NULL
	BEGIN
		IF CHARINDEX('<?xml version', @Archivo) = 0      
			SET @Archivo = '<?xml version="1.0" encoding="Windows-1252"?>' + @Archivo
		
		SELECT @Archivo = REPLACE(@Archivo, 'ï»¿', '') 

		BEGIN TRY
			SELECT @Archivo = dbo.fneDocQuitarAcentos(@Archivo)	
			
			IF CHARINDEX('Version="4.0"', @Archivo) > 0
				SELECT @PrefijoCFDI = '<ns xmlns' + CHAR(58) + 'cfdi="http' + CHAR(58) + '//www.sat.gob.mx/cfd/4" xmlns' + CHAR(58) + 'pago10="http' + CHAR(58) + '//www.sat.gob.mx/Pagos" xmlns' + CHAR(58) + 'tfd="http' + CHAR(58) + '//www.sat.gob.mx/TimbreFiscalDigital"/>'
			ELSE
				SELECT @PrefijoCFDI = '<ns xmlns' + CHAR(58) + 'cfdi="http' + CHAR(58) + '//www.sat.gob.mx/cfd/3" xmlns' + CHAR(58) + 'pago10="http' + CHAR(58) + '//www.sat.gob.mx/Pagos" xmlns' + CHAR(58) + 'tfd="http' + CHAR(58) + '//www.sat.gob.mx/TimbreFiscalDigital"/>'
		
			EXEC sp_xml_preparedocument @iDatos OUTPUT, @Archivo, @PrefijoCFDI
			
				SELECT @UUID = UUID, @FechaTimbrado = CONVERT(datetime,RTRIM(REPLACE(FechaTimbrado,'Z','')))
				FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Complemento/tfd:TimbreFiscalDigital', 1)
				WITH (UUID VARCHAR(36), FechaTimbrado VARCHAR(50)) 

				IF NULLIF(@UUID, '') IS NULL
					SELECT @Ok = 1, @OkRef = 'Archivo Inválido'

				IF @Tipo = 'ReembolsoGastos'
				BEGIN 
					IF @FechaTimbrado < (GETDATE() - 30) 
						SELECT @Ok = 1, @OkRef = 'No se pueden procesar facturas con fecha de timbrado mayor a 30 días'
				END
				ELSE IF @FechaTimbrado < (GETDATE() - @DiasVigenciaFactura) 
					SELECT @Ok = 1, @OkRef = 'No se pueden procesar facturas con fecha de timbrado mayor a ' + CONVERT(VARCHAR, @DiasVigenciaFactura) + ' días'

				SELECT @TipoDeComprobante = TipoDeComprobante
				FROM OPENXML (@IDatos, 'cfdi:Comprobante', 1)
				WITH (TipoDeComprobante VARCHAR(5)) 

				IF @Tipo = 'Factura' AND @Ok IS NULL
				BEGIN
					SELECT @RFCEmisor = Rfc
					FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Emisor', 1)
					WITH (Rfc VARCHAR(15)) 

					SELECT @RFCReceptor = Rfc
					FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Receptor', 1)
					WITH (Rfc VARCHAR(15)) 

					IF @RFCEmpresa <> @RFCReceptor
						SELECT @Ok = 1, @OkRef = 'El RFC del Receptor no concuerda con el RFC de la empresa seleccionada'
					ELSE IF @RFCCliente <> @RFCEmisor
							SELECT @Ok = 1, @OkRef = 'El RFC del Emisor no concuerda con el RFC de la Proveedor logueado'

					IF @TipoDeComprobante <> 'I'
						SELECT @Ok = 1, @OkRef = 'Tipo de comprobante no valido para esta opción'

					IF @Ok IS NULL
					BEGIN 
						IF EXISTS(SELECT * FROM FacturaXMLProveedores WHERE UUID = @UUID)
							SELECT @Ok = 1, @OkRef = 'El UUID (' + @UUID + ') ya ha sido procesado anteriormente'
						ELSE	
						BEGIN
							INSERT INTO FacturaXMLProveedores (UUID, RFCEmisor, RFCReceptor, Monto, Moneda, Fecha, Documento, Nombre, Estatus, Serie, Folio)--, Direccion)
							SELECT @UUID, @RFCEmisor, @RFCReceptor, Total, Moneda, CONVERT(datetime,RTRIM(REPLACE(Fecha,'Z',''))), @Archivo, @NombreArchivo, @Estatus, Serie, Folio --, @RutaArchivo
							FROM OPENXML (@iDatos, '/cfdi:Comprobante', 1)
							WITH (Total FLOAT, Moneda VARCHAR(3), Fecha VARCHAR(50), Serie VARCHAR(20), Folio VARCHAR(20)) 

							SELECT @ID = SCOPE_IDENTITY()

							INSERT INTO @Detalle (ClaveProdServ, NoIdentificacion, Descripcion, Cantidad, ValorUnitario, Importe, Descuento, Adicional, Exento)
							SELECT ClaveProdServ, NoIdentificacion, Descripcion, Cantidad, ValorUnitario, Importe, ISNULL(Descuento, 0), Adicional, 
									Exento = CASE WHEN CHARINDEX('Exento', Adicional) > 0 THEN 1
											 WHEN CHARINDEX('Impuestos', Adicional) > 0 THEN 0 										 
											 ELSE 1 END
							FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Conceptos/cfdi:Concepto', 9) 
							WITH (ClaveProdServ VARCHAR(20), NoIdentificacion VARCHAR(100), Descripcion VARCHAR(1000), Cantidad FLOAT, ValorUnitario MONEY, Importe MONEY, Descuento MONEY, Adicional ntext '@mp:xmltext')

							UPDATE @Detalle SET Adicional = REPLACE(Adicional, 'cfdi:', '')
			
							SELECT @Inicial = MIN(Renglon) FROM @Detalle

							WHILE @Inicial IS NOT NULL 
							BEGIN
								SELECT @Adicional = Adicional FROM @Detalle WHERE Renglon = @Inicial

								SELECT @TasaOCuota = T.Item.value('@TasaOCuota', 'DECIMAL(18,6)')
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = '002'

								SELECT @TasaOCuota2 = T.Item.value('@TasaOCuota', 'DECIMAL(18,6)')
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = '003'

								SELECT @ImporteImpuesto1 = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = '002'

								SELECT @ImporteImpuesto2 = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = '003'

								SELECT @ImpuestoDetalle = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)

								--Retenciones
								SELECT @RTasaOCuota1 = T.Item.value('@TasaOCuota', 'DECIMAL(18,6)')
								FROM @Adicional.nodes('Concepto/Impuestos/Retenciones/Retencion') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = @Retencion1

								SELECT @RTasaOCuota2 = T.Item.value('@TasaOCuota', 'DECIMAL(18,6)')
								FROM @Adicional.nodes('Concepto/Impuestos/Retenciones/Retencion') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = @Retencion2

								SELECT @ImporteRetencion1 = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Retenciones/Retencion') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = @Retencion1

								SELECT @ImporteRetencion2 = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Retenciones/Retencion') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = @Retencion2
		
								UPDATE @Detalle SET TasaOCuota = @TasaOCuota, ImporteImpuestoTotal = @ImpuestoDetalle, Impuesto1 = @Impuesto1, ImporteImpuesto1 = @ImporteImpuesto1,
													Impuesto2 = @Impuesto2, TasaOCuota2 = @TasaOCuota2, ImporteImpuesto2 = @ImporteImpuesto2, Retencion1 = @Retencion1, RTasaOCuota1 = @RTasaOCuota1,
													ImporteRetencion1 = @ImporteRetencion1, Retencion2 = @Retencion2, RTasaOCuota2 = @RTasaOCuota2, ImporteRetencion2 = @ImporteRetencion2
								WHERE Renglon = @Inicial

								SELECT @TasaOCuota = NULL, @ImpuestoDetalle = NULL, @ImporteImpuesto1 = NULL, @TasaOCuota2 = NULL, @ImporteImpuesto2 = NULL
								SET @Inicial = (SELECT MIN(Renglon) FROM @Detalle WHERE Renglon > @Inicial)
							END

							INSERT INTO FacturaXMLProveedoresD (ID, Renglon, ClaveProdServ, NoIdentificacion, Descripcion, Cantidad, ValorUnitario, Importe, TasaOCuota, Impuesto, Descuento, Adicional, Exento, Impuesto1, ImporteImpuesto1, Impuesto2, TasaOCuota2, ImporteImpuesto2, Retencion1, RTasaOCuota1, ImporteRetencion1, Retencion2, RTasaOCuota2, ImporteRetencion2)
							SELECT @ID, Renglon, ClaveProdServ, NoIdentificacion, Descripcion, Cantidad, ValorUnitario, Importe, TasaOCuota, ImporteImpuestoTotal, Descuento, Adicional, Exento, Impuesto1, ImporteImpuesto1, Impuesto2, TasaOCuota2, ImporteImpuesto2, Retencion1, RTasaOCuota1, ImporteRetencion1, Retencion2, RTasaOCuota2, ImporteRetencion2
							FROM @Detalle
						END
					END
				END

				IF @Tipo = 'Nota' AND @Ok IS NULL
				BEGIN					
					SELECT @RFCEmisor = Rfc
					FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Emisor', 1)
					WITH (Rfc VARCHAR(15)) 

					SELECT @RFCReceptor = Rfc
					FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Receptor', 1)
					WITH (Rfc VARCHAR(15)) 

					IF @RFCEmpresa <> @RFCReceptor
						SELECT @Ok = 1, @OkRef = 'El RFC del Receptor no concuerda con el RFC de la empresa seleccionada'
					ELSE IF @RFCCliente <> @RFCEmisor
							SELECT @Ok = 1, @OkRef = 'El RFC del Emisor no concuerda con el RFC de la Proveedor logueado'

					IF @TipoDeComprobante <> 'E'
						SELECT @Ok = 1, @OkRef = 'Tipo de comprobante no valido para esta opción'

					IF @Ok IS NULL
					BEGIN 
						IF EXISTS(SELECT * FROM NotaXMLProveedores WHERE UUID = @UUID)
							SELECT @Ok = 1, @OkRef = 'El UUID (' + @UUID + ') ya ha sido procesado anteriormente'
						ELSE
						BEGIN 
							INSERT INTO NotaXMLProveedores (UUID, RFCEmisor, RFCReceptor, Monto, Moneda, Fecha, Documento, Nombre, Estatus, Serie, Folio)--, Direccion)
							SELECT @UUID, @RFCEmisor, @RFCReceptor, Total, Moneda, CONVERT(datetime,RTRIM(REPLACE(Fecha,'Z',''))), @Archivo, @NombreArchivo, 'Pendiente', Serie, Folio --, @RutaArchivo
							FROM OPENXML (@iDatos, '/cfdi:Comprobante', 1)
							WITH (Total FLOAT, Moneda VARCHAR(3), Fecha varchar(50), Serie VARCHAR(20), Folio VARCHAR(20)) 

							SELECT @ID = SCOPE_IDENTITY()

							INSERT INTO NotaXMLProveedoresD (ID, UUIDRelacionado)
							SELECT @ID, UUID
							FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:CfdiRelacionados/cfdi:CfdiRelacionado', 1)
							WITH (UUID VARCHAR(36)) 

							IF NOT EXISTS(SELECT * FROM NotaXMLProveedoresD WHERE ID = @ID)
								SELECT @Ok = 1, @OkRef = 'El UUID (' + @UUID + ') No tiene CFDIs Relacionados'
						END
					END
				END

				IF @Tipo = 'Complemento' AND @Ok IS NULL
				BEGIN
					SELECT @RFCEmisor = Rfc
					FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Emisor', 1)
					WITH (Rfc VARCHAR(15)) 

					SELECT @RFCReceptor = Rfc
					FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Receptor', 1)
					WITH (Rfc VARCHAR(15)) 

					IF @RFCEmpresa <> @RFCReceptor
						SELECT @Ok = 1, @OkRef = 'El RFC del Receptor no concuerda con el RFC de la empresa seleccionada'
					ELSE IF @RFCCliente <> @RFCEmisor
							SELECT @Ok = 1, @OkRef = 'El RFC del Emisor no concuerda con el RFC de la Proveedor logueado'

					IF @TipoDeComprobante <> 'P'
						SELECT @Ok = 1, @OkRef = 'Tipo de comprobante no valido para esta opción'

					IF @Ok IS NULL
					BEGIN 
						IF EXISTS(SELECT * FROM ComplementoXMLProveedores WHERE UUID = @UUID)
							SELECT @Ok = 1, @OkRef = 'El UUID (' + @UUID + ') ya ha sido procesado anteriormente'
						ELSE
						BEGIN 
							INSERT INTO ComplementoXMLProveedores (UUID, RFCEmisor, RFCReceptor, Monto, Moneda, Fecha, Documento, Nombre, Estatus, Serie, Folio)--, Direccion)
							SELECT @UUID, @RFCEmisor, @RFCReceptor, Total, Moneda, CONVERT(datetime,RTRIM(REPLACE(Fecha,'Z',''))), @Archivo, @NombreArchivo, 'Pendiente', Serie, Folio --, @RutaArchivo
							FROM OPENXML (@iDatos, '/cfdi:Comprobante', 1)
							WITH (Total FLOAT, Moneda VARCHAR(3), Fecha varchar(50), Serie VARCHAR(20), Folio VARCHAR(20)) 

							SELECT @ID = SCOPE_IDENTITY()

							INSERT INTO ComplementoXMLProveedoresD (ID, UUIDRelacionado, Folio, Serie, NumParcialidad, MonedaDR, MetodoDePagoDR, ImpSaldoInsoluto, ImpSaldoAnt, ImpPagado)
							SELECT @ID, IdDocumento, Folio, Serie, NumParcialidad, MonedaDR, MetodoDePagoDR, ImpSaldoInsoluto, ImpSaldoAnt, ImpPagado
							FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Complemento/pago10:Pagos/pago10:Pago/pago10:DoctoRelacionado', 1)
							WITH (IdDocumento VARCHAR(36), Folio VARCHAR(20), Serie VARCHAR(20), NumParcialidad INT, MonedaDR VARCHAR(3), MetodoDePagoDR VARCHAR(5),
							ImpSaldoInsoluto FLOAT, ImpSaldoAnt FLOAT, ImpPagado FLOAT) 
						END
					END
				END

				IF @Tipo = 'ReembolsoGastos' AND @Ok IS NULL
				BEGIN
					SELECT @RFCEmisor = Rfc
					FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Emisor', 1)
					WITH (Rfc VARCHAR(15)) 

					SELECT @RFCReceptor = Rfc
					FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Receptor', 1)
					WITH (Rfc VARCHAR(15)) 

					IF @RFCEmpresa <> @RFCReceptor
						SELECT @Ok = 1, @OkRef = 'El RFC del Receptor no concuerda con el RFC de la empresa seleccionada'

					IF @TipoDeComprobante <> 'I'
						SELECT @Ok = 1, @OkRef = 'Tipo de comprobante no valido para esta opción'

					IF @Ok IS NULL
					BEGIN 
						IF EXISTS(SELECT TOP 1 * FROM FacturaXMLReembolsoGastos F
									JOIN ReembolsoGastos R ON R.IDReembolsoGastos = F.IDReembolsoGastos 
									WHERE UUID = @UUID AND R.Estatus <> 'SINAFECTAR')
							SELECT @Ok = 1, @OkRef = 'El UUID (' + @UUID + ') ya ha sido procesado anteriormente'
						ELSE	
						BEGIN
							INSERT INTO FacturaXMLReembolsoGastos (IDReembolsoGastos, UUID, RFCEmisor, RFCReceptor, Monto, Moneda, Fecha, Documento, Nombre, Serie, Folio, TipoMovimiento)
							SELECT @IDReembolsoGastos, @UUID, @RFCEmisor, @RFCReceptor, Total, Moneda, CONVERT(datetime,RTRIM(REPLACE(Fecha,'Z',''))), @Archivo, @NombreArchivo, Serie, Folio, @Tipo
							FROM OPENXML (@iDatos, '/cfdi:Comprobante', 1)
							WITH (Total FLOAT, Moneda VARCHAR(3), Fecha VARCHAR(50), Serie VARCHAR(20), Folio VARCHAR(20)) 

							SELECT @ID = SCOPE_IDENTITY()

							INSERT INTO @Detalle (ClaveProdServ, NoIdentificacion, Descripcion, Cantidad, ValorUnitario, Importe, Descuento, Adicional, Exento)
							SELECT ClaveProdServ, NoIdentificacion, Descripcion, Cantidad, ValorUnitario, Importe, ISNULL(Descuento, 0), Adicional, 
									Exento = CASE WHEN CHARINDEX('Exento', Adicional) > 0 THEN 1
											 WHEN CHARINDEX('Impuestos', Adicional) > 0 THEN 0 										 
											 ELSE 1 END
							FROM OPENXML (@iDatos, 'cfdi:Comprobante/cfdi:Conceptos/cfdi:Concepto', 9) 
							WITH (ClaveProdServ VARCHAR(20), NoIdentificacion VARCHAR(100), Descripcion VARCHAR(1000), Cantidad FLOAT, ValorUnitario MONEY, Importe MONEY, Descuento MONEY, Adicional ntext '@mp:xmltext')

							UPDATE @Detalle SET Adicional = REPLACE(Adicional, 'cfdi:', '')
			
							SELECT @Inicial = MIN(Renglon) FROM @Detalle

							WHILE @Inicial IS NOT NULL 
							BEGIN
								SELECT @Adicional = Adicional FROM @Detalle WHERE Renglon = @Inicial

								SELECT @TasaOCuota = T.Item.value('@TasaOCuota', 'DECIMAL(18,6)')
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = '002'

								SELECT @TasaOCuota2 = T.Item.value('@TasaOCuota', 'DECIMAL(18,6)')
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = '003'

								SELECT @ImporteImpuesto1 = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = '002'

								SELECT @ImporteImpuesto2 = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = '003'

								SELECT @ImpuestoDetalle = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Traslados/Traslado') AS T(Item)

								--Retenciones
								SELECT @RTasaOCuota1 = T.Item.value('@TasaOCuota', 'DECIMAL(18,6)')
								FROM @Adicional.nodes('Concepto/Impuestos/Retenciones/Retencion') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = @Retencion1

								SELECT @RTasaOCuota2 = T.Item.value('@TasaOCuota', 'DECIMAL(18,6)')
								FROM @Adicional.nodes('Concepto/Impuestos/Retenciones/Retencion') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = @Retencion2

								SELECT @ImporteRetencion1 = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Retenciones/Retencion') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = @Retencion1

								SELECT @ImporteRetencion2 = SUM(T.Item.value('@Importe', 'MONEY'))
								FROM @Adicional.nodes('Concepto/Impuestos/Retenciones/Retencion') AS T(Item)
								WHERE T.Item.value('@Impuesto', 'NVARCHAR(3)') = @Retencion2
		
								UPDATE @Detalle SET TasaOCuota = @TasaOCuota, ImporteImpuestoTotal = @ImpuestoDetalle, Impuesto1 = @Impuesto1, ImporteImpuesto1 = @ImporteImpuesto1,
													Impuesto2 = @Impuesto2, TasaOCuota2 = @TasaOCuota2, ImporteImpuesto2 = @ImporteImpuesto2, Retencion1 = @Retencion1, RTasaOCuota1 = @RTasaOCuota1,
													ImporteRetencion1 = @ImporteRetencion1, Retencion2 = @Retencion2, RTasaOCuota2 = @RTasaOCuota2, ImporteRetencion2 = @ImporteRetencion2
								WHERE Renglon = @Inicial

								SELECT @TasaOCuota = NULL, @ImpuestoDetalle = NULL, @ImporteImpuesto1 = NULL, @TasaOCuota2 = NULL, @ImporteImpuesto2 = NULL
								SET @Inicial = (SELECT MIN(Renglon) FROM @Detalle WHERE Renglon > @Inicial)
							END

							INSERT INTO FacturaXMLReembolsoGastosD (ID, Renglon, ClaveProdServ, NoIdentificacion, Descripcion, Cantidad, ValorUnitario, Importe, TasaOCuota, Impuesto, Descuento, Adicional, Exento, Impuesto1, ImporteImpuesto1, Impuesto2, TasaOCuota2, ImporteImpuesto2, Retencion1, RTasaOCuota1, ImporteRetencion1, Retencion2, RTasaOCuota2, ImporteRetencion2)
							SELECT @ID, Renglon, ClaveProdServ, NoIdentificacion, Descripcion, Cantidad, ValorUnitario, Importe, TasaOCuota, ImporteImpuestoTotal, Descuento, Adicional, Exento, Impuesto1, ImporteImpuesto1, Impuesto2, TasaOCuota2, ImporteImpuesto2, Retencion1, RTasaOCuota1, ImporteRetencion1, Retencion2, RTasaOCuota2, ImporteRetencion2
							FROM @Detalle
						END
					END
				END

			EXEC sp_xml_removedocument @iDatos
		END TRY 
		BEGIN CATCH 
			SELECT @Ok = 1, @OkRef = ERROR_MESSAGE()  
		END CATCH 
	END

	IF @Ok IS NULL      
	BEGIN      
		COMMIT TRAN         
	END      
	ELSE      
	BEGIN      
		ROLLBACK TRAN         
	END  
RETURN
END
GO
