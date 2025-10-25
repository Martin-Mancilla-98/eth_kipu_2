
Este proyecto simula el proceso real de desarrollar, mantener y escalar contratos inteligentes en entornos de producción, integrando control de acceso, soporte multi‑token, oráculos de datos y patrones de seguridad.

---

## ✨ Mejoras realizadas
- **Control de acceso:** integración de `AccessControl` de OpenZeppelin con roles `DEFAULT_ADMIN_ROLE` y `ADMIN_ROLE` para restringir funciones críticas.
- **Soporte multi‑token:** depósitos y retiros de Ether (`address(0)`) y ERC‑20 registrados.
- **Contabilidad interna:** balances por usuario y token, normalizados a 6 decimales (USDC).
- **Oráculo Chainlink:** integración del feed ETH/USD en Sepolia para calcular equivalentes en USD.
- **Cap global del banco:** límite de `100,000 USDC` en depósitos de ETH.
- **Eventos y errores personalizados:** para mejorar trazabilidad y debugging (`Deposito`, `Retiro`, `TokenRegistrado`, `BankCapReached`).
- **Conversión de decimales:** función que normaliza montos de distintos tokens a 6 decimales.
- **Patrones de seguridad:** uso de Checks‑Effects‑Interactions, variables `constant`/`immutable`, validaciones en constructor, y funciones `receive`/`fallback`.
- **Documentación NatSpec completa:** cada función cuenta con anotaciones claras.

---

## 🛠️ Despliegue en Testnet
- **Red:** Sepolia Testnet  
- **Cuenta admin:** `0xe4De0D7995D0E307Da31F3f020B8C2C7D255db6a`  
- **Oráculo ETH/USD (Sepolia):** `0x694AA1769357215DE4FAC081bf1f309aDC325306`  
- **Contrato desplegado:**  
  👉 [0x5CA4ce34f6361d443DaBa28Efa6b09fd97d6B974]
(https://sepolia.etherscan.io/address/0x5CA4ce34f6361d443DaBa28Efa6b09fd97d6B974)  
  

---

## Instrucciones de interacción

### Depositar Ether
1. En Remix, en el campo **Value**, ingresar el monto en wei (ejemplo: `1000000000000000` = 0.001 ETH).
2. Ejecutar `depositarEther()`.
3. Verificar evento `Deposito` y el balance 

### Registrar un token ERC‑20
```solidity
registrarToken(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238, 6)
